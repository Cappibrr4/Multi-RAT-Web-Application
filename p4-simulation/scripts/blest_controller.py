#!/usr/bin/env python3
"""
BLEST Controller — Dynamic RTT Monitor for P4 Switch
=====================================================

This script acts as a lightweight SDN controller that:
  1. Periodically probes each path's RTT (via ICMP or TCP timestamps)
  2. Updates the P4 switch's path_rtt registers with fresh measurements
  3. Reads and displays path utilization statistics
  4. Adjusts the BLEST lambda parameter if needed

This is the "controller plane" component that feeds the P4 data plane
with the path-quality information it needs for BLEST scheduling.

In a production deployment, this would run on an SDN controller
(ONOS, Ryu, Floodlight) or use P4Runtime gRPC. Here we use
simple_switch_CLI for BMv2 compatibility.

Usage:
    sudo python3 blest_controller.py [--interval 5] [--thrift-port 9090]
"""

import subprocess
import time
import re
import argparse
import signal
import sys
import json
from datetime import datetime


class BLESTController:
    """Monitors path RTTs and updates P4 switch registers."""

    def __init__(self, thrift_port=9090, interval=5):
        self.thrift_port = thrift_port
        self.interval = interval
        self.running = True
        self.history = []

        # Path endpoints for probing
        # These are the next-hop IPs on each path from S1's perspective
        self.path_targets = {
            0: '10.0.2.1',  # Via Path A (through S2)
            1: '10.0.2.1',  # Via Path B (through S3)
        }

        signal.signal(signal.SIGINT, self._handle_signal)

    def _handle_signal(self, sig, frame):
        print("\nStopping controller...")
        self.running = False

    def _cli_cmd(self, command):
        """Send a command to simple_switch_CLI."""
        proc = subprocess.Popen(
            ['simple_switch_CLI', '--thrift-port', str(self.thrift_port)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE)
        out, err = proc.communicate(command.encode())
        return out.decode().strip()

    def read_register(self, name, index):
        """Read a register value from the switch."""
        out = self._cli_cmd(f'register_read {name} {index}')
        # Parse "MyIngress.path_rtt[0]= 10000"
        match = re.search(r'=\s*(\d+)', out)
        return int(match.group(1)) if match else 0

    def write_register(self, name, index, value):
        """Write a register value on the switch."""
        self._cli_cmd(f'register_write {name} {index} {value}')

    def read_counter(self, name, index):
        """Read a counter value from the switch."""
        out = self._cli_cmd(f'counter_read {name} {index}')
        # Parse "MyIngress.path_counter[0]= BmCounterValue(packets=100, bytes=64000)"
        pkts = re.search(r'packets=(\d+)', out)
        byts = re.search(r'bytes=(\d+)', out)
        return {
            'packets': int(pkts.group(1)) if pkts else 0,
            'bytes': int(byts.group(1)) if byts else 0,
        }

    def probe_rtt(self, target, via_port=None):
        """
        Probe RTT to a target using ICMP ping.
        In a real deployment, you'd use INT or TCP timestamp probes.
        """
        try:
            result = subprocess.run(
                ['ping', '-c', '3', '-W', '2', target],
                capture_output=True, text=True, timeout=10)
            match = re.search(
                r'rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)',
                result.stdout)
            if match:
                return int(float(match.group(2)) * 1000)  # ms → us
        except (subprocess.TimeoutExpired, Exception):
            pass
        return None

    def get_path_stats(self):
        """Read all path statistics from the switch."""
        stats = {}
        for i in range(2):
            stats[f'path_{i}'] = {
                'rtt_us': self.read_register('path_rtt', i),
                'pkt_count': self.read_register('path_pkt_count', i),
                'counter': self.read_counter('path_counter', i),
            }
        stats['lambda'] = self.read_register('lambda_reg', 0)
        return stats

    def update_rtt(self, path_idx, rtt_us):
        """Update a path's RTT register on the switch."""
        self.write_register('path_rtt', path_idx, rtt_us)

    def run(self):
        """Main controller loop."""
        print(f"BLEST Controller started (thrift port {self.thrift_port})")
        print(f"Polling interval: {self.interval}s")
        print("-" * 60)

        iteration = 0
        while self.running:
            iteration += 1
            now = datetime.now().strftime('%H:%M:%S')

            # Read current stats
            stats = self.get_path_stats()

            # Display
            print(f"\n[{now}] Iteration {iteration}")
            for i in range(2):
                p = stats[f'path_{i}']
                rtt_ms = p['rtt_us'] / 1000 if p['rtt_us'] > 0 else '?'
                print(f"  Path {chr(65+i)}: RTT={rtt_ms}ms  "
                      f"pkts={p['pkt_count']:>8}  "
                      f"bytes={p['counter']['bytes']:>12}")

            lam = stats['lambda']
            print(f"  Lambda: {lam/1000:.3f}")

            # Calculate utilization balance
            p0_pkts = stats['path_0']['pkt_count']
            p1_pkts = stats['path_1']['pkt_count']
            total = p0_pkts + p1_pkts
            if total > 0:
                balance = min(p0_pkts, p1_pkts) / max(p0_pkts, p1_pkts) * 100
                print(f"  Balance: {balance:.1f}% "
                      f"(A:{p0_pkts/total*100:.0f}% / B:{p1_pkts/total*100:.0f}%)")

            # Log to history
            self.history.append({
                'time': now,
                'iteration': iteration,
                'stats': stats,
            })

            time.sleep(self.interval)

        # Save history on exit
        if self.history:
            outfile = f'/tmp/blest_controller_{int(time.time())}.json'
            with open(outfile, 'w') as f:
                json.dump(self.history, f, indent=2)
            print(f"\nHistory saved to {outfile}")


def main():
    parser = argparse.ArgumentParser(description='BLEST P4 Controller')
    parser.add_argument('--thrift-port', type=int, default=9090,
                        help='BMv2 thrift port (default: 9090)')
    parser.add_argument('--interval', type=int, default=5,
                        help='Polling interval in seconds (default: 5)')
    parser.add_argument('--set-rtt', nargs=3, metavar=('PATH', 'RTT_US', ''),
                        help='Set RTT for a path and exit (e.g., --set-rtt 0 10000)')
    args = parser.parse_args()

    if args.set_rtt:
        ctrl = BLESTController(args.thrift_port)
        path_idx = int(args.set_rtt[0])
        rtt_us = int(args.set_rtt[1])
        ctrl.update_rtt(path_idx, rtt_us)
        print(f"Set path {path_idx} RTT to {rtt_us}us ({rtt_us/1000}ms)")
        return

    ctrl = BLESTController(args.thrift_port, args.interval)
    ctrl.run()


if __name__ == '__main__':
    main()
