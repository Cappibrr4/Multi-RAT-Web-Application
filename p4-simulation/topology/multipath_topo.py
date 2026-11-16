#!/usr/bin/env python3
"""
Multipath Topology for P4 Switch Scheduling Simulation
=======================================================

Topology:
                    ┌──── S2 (path A) ────┐
   H1 ──── S1 ─────┤                     ├───── S4 ──── H2
                    └──── S3 (path B) ────┘

- H1 (10.0.1.1): Sender host
- H2 (10.0.2.1): Receiver host
- S1: Ingress switch (runs the P4 multipath scheduler)
- S2: Path A relay (can add delay/loss to simulate heterogeneous links)
- S3: Path B relay (can add different delay/loss)
- S4: Egress switch (merges traffic back)

This topology demonstrates:
  1. S1 distributes packets across two paths using the P4 scheduler
  2. S2 and S3 represent different network paths (e.g., WiFi vs LTE)
  3. S4 reassembles traffic toward H2
  4. Comparing this against single-path and endpoint-based scheduling

Usage:
    sudo python3 multipath_topo.py [--scheduler rr|blest] [--delay-a 10] [--delay-b 50]
"""

import argparse
import os
import sys
import time
import json
import subprocess

from mininet.net import Mininet
from mininet.topo import Topo
from mininet.link import TCLink
from mininet.log import setLogLevel, info
from mininet.cli import CLI
from mininet.node import Switch


class P4Switch(Switch):
    """BMv2 simple_switch as a Mininet switch."""

    device_id = 0

    def __init__(self, name, sw_path='simple_switch',
                 json_path=None, thrift_port=None,
                 log_console=False, **kwargs):
        Switch.__init__(self, name, **kwargs)
        self.sw_path = sw_path
        self.json_path = json_path
        self.thrift_port = thrift_port or (9090 + P4Switch.device_id)
        self.log_console = log_console
        self.device_id = P4Switch.device_id
        P4Switch.device_id += 1

    def start(self, controllers):
        """Start the BMv2 switch."""
        info(f"Starting P4 switch {self.name} (device_id={self.device_id})\n")

        # Build interface list
        ifaces = []
        for intf in self.intfList():
            if intf.name != 'lo':
                ifaces += ['-i', f'{self.ports[intf]}@{intf.name}']

        log_file = f'/tmp/p4s.{self.name}.log'
        cmd = [self.sw_path,
               '--device-id', str(self.device_id),
               '--thrift-port', str(self.thrift_port)]
        cmd += ifaces

        if self.json_path:
            cmd += [self.json_path]

        cmd += ['--log-console' if self.log_console else f'--log-file={log_file}']

        info(f"  CMD: {' '.join(cmd)}\n")
        self.cmd(' '.join(cmd) + ' &')
        time.sleep(1)
        info(f"  {self.name} running on thrift port {self.thrift_port}\n")

    def stop(self, deleteIntfs=True):
        """Stop the BMv2 switch."""
        self.cmd('kill %simple_switch 2>/dev/null || true')
        Switch.stop(self, deleteIntfs)


class MultipathTopo(Topo):
    """
    Multi-path topology with 4 switches and 2 hosts.
    S1 is the scheduler switch; S2/S3 are the two paths; S4 merges.
    """

    def build(self, delay_a='10ms', delay_b='50ms',
              bw_a=10, bw_b=10, loss_a=0, loss_b=0, **opts):
        """
        Args:
            delay_a: Latency on Path A (S1-S2-S4)
            delay_b: Latency on Path B (S1-S3-S4)
            bw_a:    Bandwidth on Path A (Mbps)
            bw_b:    Bandwidth on Path B (Mbps)
            loss_a:  Packet loss on Path A (percent)
            loss_b:  Packet loss on Path B (percent)
        """
        info(f"\n=== Building Multipath Topology ===\n")
        info(f"  Path A: delay={delay_a}, bw={bw_a}Mbps, loss={loss_a}%\n")
        info(f"  Path B: delay={delay_b}, bw={bw_b}Mbps, loss={loss_b}%\n\n")

        # ── Hosts ──
        h1 = self.addHost('h1', ip='10.0.1.1/24',
                          defaultRoute='via 10.0.1.254')
        h2 = self.addHost('h2', ip='10.0.2.1/24',
                          defaultRoute='via 10.0.2.254')

        # ── Switches ──
        # S1: Ingress (runs the multipath scheduler P4 program)
        s1 = self.addSwitch('s1', cls=P4Switch)
        # S2: Path A relay
        s2 = self.addSwitch('s2', cls=P4Switch)
        # S3: Path B relay
        s3 = self.addSwitch('s3', cls=P4Switch)
        # S4: Egress (merges paths)
        s4 = self.addSwitch('s4', cls=P4Switch)

        # ── Links ──
        # H1 to S1 (no impairment on access link)
        self.addLink(h1, s1, port2=1,
                     cls=TCLink, bw=100, delay='1ms')

        # S1 to S2 (Path A — low delay)
        self.addLink(s1, s2, port1=2, port2=1,
                     cls=TCLink, bw=bw_a, delay=delay_a, loss=loss_a)

        # S1 to S3 (Path B — high delay, simulating heterogeneous link)
        self.addLink(s1, s3, port1=3, port2=1,
                     cls=TCLink, bw=bw_b, delay=delay_b, loss=loss_b)

        # S2 to S4 (Path A continuation)
        self.addLink(s2, s4, port1=2, port2=1,
                     cls=TCLink, bw=bw_a, delay=delay_a, loss=loss_a)

        # S3 to S4 (Path B continuation)
        self.addLink(s3, s4, port1=2, port2=2,
                     cls=TCLink, bw=bw_b, delay=delay_b, loss=loss_b)

        # S4 to H2 (no impairment on access link)
        self.addLink(s4, h2, port1=3,
                     cls=TCLink, bw=100, delay='1ms')


def install_flow_rules(net, scheduler):
    """
    Install flow rules on each switch via simple_switch_CLI.

    S1 (scheduler switch): multipath_route table sends matching traffic
        through the P4 RR/BLEST scheduler action.
    S2, S3: Simple forwarding (port 1 → port 2, port 2 → port 1).
    S4: Forward from ports 1,2 → port 3 (merge paths to H2).
    """
    info("\n=== Installing Flow Rules ===\n")

    def cli_cmd(switch_name, thrift_port, commands):
        """Send commands to simple_switch_CLI."""
        cmd_str = '\n'.join(commands)
        proc = subprocess.Popen(
            ['simple_switch_CLI', '--thrift-port', str(thrift_port)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE)
        out, err = proc.communicate(cmd_str.encode())
        if err:
            info(f"  {switch_name} CLI stderr: {err.decode()}\n")
        return out.decode()

    h1_mac = net.get('h1').MAC()
    h2_mac = net.get('h2').MAC()

    # ── S1: Ingress scheduler switch ──
    s1_cmds = [
        # Multipath route: packets to H2's subnet get scheduled
        f'table_add multipath_route multipath_{"rr" if scheduler == "rr" else "blest"}_select 10.0.2.0/24 =>',
        # Fallback: packets to H1's subnet go back out port 1
        f'table_add ipv4_lpm forward 10.0.1.0/24 => 1 {h1_mac}',
    ]
    info(f"  S1 (scheduler): {cli_cmd('s1', 9090, s1_cmds)}\n")

    # ── S2: Path A forwarder ──
    s2_cmds = [
        f'table_add ipv4_lpm forward 10.0.2.0/24 => 2 {h2_mac}',
        f'table_add ipv4_lpm forward 10.0.1.0/24 => 1 {h1_mac}',
    ]
    info(f"  S2 (path A): {cli_cmd('s2', 9091, s2_cmds)}\n")

    # ── S3: Path B forwarder ──
    s3_cmds = [
        f'table_add ipv4_lpm forward 10.0.2.0/24 => 2 {h2_mac}',
        f'table_add ipv4_lpm forward 10.0.1.0/24 => 1 {h1_mac}',
    ]
    info(f"  S3 (path B): {cli_cmd('s3', 9092, s3_cmds)}\n")

    # ── S4: Egress merge switch ──
    s4_cmds = [
        f'table_add ipv4_lpm forward 10.0.2.0/24 => 3 {h2_mac}',
        f'table_add ipv4_lpm forward 10.0.1.0/24 => 1 {h1_mac}',
    ]
    info(f"  S4 (egress): {cli_cmd('s4', 9093, s4_cmds)}\n")


def set_blest_rtt(path_idx, rtt_us, thrift_port=9090):
    """Update path RTT register on S1 for the BLEST scheduler."""
    cmd = f'register_write path_rtt {path_idx} {rtt_us}'
    proc = subprocess.Popen(
        ['simple_switch_CLI', '--thrift-port', str(thrift_port)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE)
    proc.communicate(cmd.encode())


def read_path_stats(thrift_port=9090):
    """Read per-path packet counters from S1."""
    cmds = ['register_read path_pkt_count 0',
            'register_read path_pkt_count 1']
    cmd_str = '\n'.join(cmds)
    proc = subprocess.Popen(
        ['simple_switch_CLI', '--thrift-port', str(thrift_port)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE)
    out, _ = proc.communicate(cmd_str.encode())
    return out.decode()


def main():
    parser = argparse.ArgumentParser(
        description='Multipath P4 Scheduler Simulation')
    parser.add_argument('--scheduler', choices=['rr', 'blest'],
                        default='rr',
                        help='Scheduler to use (default: rr)')
    parser.add_argument('--delay-a', default='10ms',
                        help='Path A delay (default: 10ms)')
    parser.add_argument('--delay-b', default='50ms',
                        help='Path B delay (default: 50ms)')
    parser.add_argument('--bw-a', type=int, default=10,
                        help='Path A bandwidth in Mbps (default: 10)')
    parser.add_argument('--bw-b', type=int, default=10,
                        help='Path B bandwidth in Mbps (default: 10)')
    parser.add_argument('--loss-a', type=float, default=0,
                        help='Path A loss %% (default: 0)')
    parser.add_argument('--loss-b', type=float, default=0,
                        help='Path B loss %% (default: 0)')
    parser.add_argument('--cli', action='store_true',
                        help='Drop into Mininet CLI after setup')
    args = parser.parse_args()

    setLogLevel('info')

    # Reset P4Switch device IDs
    P4Switch.device_id = 0

    # Compile P4 program
    p4_dir = os.path.join(os.path.dirname(__file__), '..', 'p4src')
    if args.scheduler == 'rr':
        p4_src = os.path.join(p4_dir, 'multipath_rr.p4')
    else:
        p4_src = os.path.join(p4_dir, 'multipath_blest.p4')

    json_out = f'/tmp/multipath_{args.scheduler}.json'

    info(f"\n=== Compiling {p4_src} ===\n")
    ret = os.system(f'p4c --target bmv2 --arch v1model '
                    f'-o /tmp/p4out_{args.scheduler} '
                    f'--p4runtime-files /tmp/p4info_{args.scheduler}.txt '
                    f'{p4_src}')
    if ret != 0:
        print("ERROR: P4 compilation failed!")
        sys.exit(1)

    json_out = f'/tmp/p4out_{args.scheduler}/multipath_{args.scheduler}.json'
    info(f"  Compiled to {json_out}\n")

    # Set JSON path for all switches
    # S1 uses the scheduler P4 program; S2-S4 use a basic forwarder
    # For simplicity, all switches run the same program but only S1
    # has multipath_route table entries installed
    P4Switch.device_id = 0

    # Build topology
    topo = MultipathTopo(
        delay_a=args.delay_a,
        delay_b=args.delay_b,
        bw_a=args.bw_a,
        bw_b=args.bw_b,
        loss_a=args.loss_a,
        loss_b=args.loss_b,
    )

    # Create network
    net = Mininet(topo=topo, link=TCLink, controller=None)

    # Set JSON path for each switch
    for sw in net.switches:
        sw.json_path = json_out

    net.start()

    # Wait for switches to be ready
    time.sleep(2)

    # Set static ARP — P4 switches don't handle ARP packets
    h1 = net.get('h1')
    h2 = net.get('h2')
    # Each host needs a fake gateway MAC so it can send off-subnet
    h1.cmd('arp -s 10.0.1.254 00:00:0a:00:01:fe')
    h2.cmd('arp -s 10.0.2.254 00:00:0a:00:02:fe')
    # Also add cross-subnet entries so the final rewritten MAC is recognized
    h1.cmd(f'arp -s 10.0.2.1 {h2.MAC()}')
    h2.cmd(f'arp -s 10.0.1.1 {h1.MAC()}')

    # Disable offloading on host interfaces (can cause issues with BMv2)
    for h in [h1, h2]:
        intf = h.defaultIntf().name
        h.cmd(f'ethtool -K {intf} tx off rx off tso off gso off gro off 2>/dev/null || true')

    # Install flow rules
    install_flow_rules(net, args.scheduler)

    # If using BLEST, set initial RTT estimates
    if args.scheduler == 'blest':
        # Parse delay values to microseconds
        delay_a_us = int(args.delay_a.replace('ms', '')) * 1000
        delay_b_us = int(args.delay_b.replace('ms', '')) * 1000
        set_blest_rtt(0, delay_a_us)
        set_blest_rtt(1, delay_b_us)
        info(f"\n  BLEST RTT set: Path A = {delay_a_us}us, "
             f"Path B = {delay_b_us}us\n")

    info("\n=== Network Ready ===\n")
    info(f"  Scheduler: {args.scheduler.upper()}\n")
    info(f"  H1: {net.get('h1').IP()}\n")
    info(f"  H2: {net.get('h2').IP()}\n")
    info(f"\nTest: h1 ping h2\n")
    info(f"Benchmark: see scripts/run_benchmark.sh\n\n")

    if args.cli:
        CLI(net)
    else:
        # Run quick connectivity test
        info("=== Connectivity Test ===\n")
        result = net.get('h1').cmd(f'ping -c 4 {net.get("h2").IP()}')
        info(result + '\n')

        # Show path stats
        info("\n=== Path Statistics ===\n")
        stats = read_path_stats()
        info(stats + '\n')

    net.stop()


if __name__ == '__main__':
    main()
