#!/usr/bin/env python3
"""Run each scenario: start topology, run iperf3, print results, stop."""
import sys, os, time, json, re
sys.path.insert(0, os.path.expanduser('~/p4-simulation/topology'))
from multipath_topo import *

setLogLevel('info')

scenarios = [
    ('rr',    '10ms', '10ms', 10, 10, 0, 0, 'RR_Symmetric'),
    ('blest', '10ms', '10ms', 10, 10, 0, 0, 'BLEST_Symmetric'),
    ('rr',    '10ms', '50ms', 10, 10, 0, 0, 'RR_Asymmetric_50ms'),
    ('blest', '10ms', '50ms', 10, 10, 0, 0, 'BLEST_Asymmetric_50ms'),
    ('rr',    '10ms', '80ms', 20,  5, 0, 0, 'RR_WiFi_vs_LTE'),
    ('blest', '10ms', '80ms', 20,  5, 0, 0, 'BLEST_WiFi_vs_LTE'),
]

DURATION = 30
results = []

for sched, da, db, bwa, bwb, la, lb, label in scenarios:
    print(f"\n{'='*60}")
    print(f"  {label}: scheduler={sched}, PathA({da},{bwa}Mbps) PathB({db},{bwb}Mbps)")
    print(f"{'='*60}")

    # Clean up any leftover Mininet
    os.system('mn -c 2>/dev/null')
    time.sleep(2)

    # Reset device IDs
    P4Switch.device_id = 0

    # Compile P4
    p4_dir = os.path.expanduser('~/p4-simulation/p4src')
    p4_src = os.path.join(p4_dir, f'multipath_{sched}.p4')
    os.system(
        f'p4c --target bmv2 --arch v1model -o /tmp/p4out_{sched} '
        f'--p4runtime-files /tmp/p4info_{sched}.txt {p4_src} 2>/dev/null'
    )
    json_out = f'/tmp/p4out_{sched}/multipath_{sched}.json'

    # Build topology
    topo = MultipathTopo(
        delay_a=da, delay_b=db,
        bw_a=bwa, bw_b=bwb,
        loss_a=la, loss_b=lb,
    )
    net = Mininet(topo=topo, link=TCLink, controller=None)
    for sw in net.switches:
        sw.json_path = json_out
    net.start()
    time.sleep(3)

    h1 = net.get('h1')
    h2 = net.get('h2')
    h1.cmd('arp -s 10.0.1.254 00:00:0a:00:01:fe')
    h2.cmd('arp -s 10.0.2.254 00:00:0a:00:02:fe')
    h1.cmd(f'arp -s 10.0.2.1 {h2.MAC()}')
    h2.cmd(f'arp -s 10.0.1.1 {h1.MAC()}')
    for h in [h1, h2]:
        intf = h.defaultIntf().name
        h.cmd(f'ethtool -K {intf} tx off rx off tso off gso off gro off 2>/dev/null')

    install_flow_rules(net, sched)

    if sched == 'blest':
        da_us = int(da.replace('ms', '')) * 1000
        db_us = int(db.replace('ms', '')) * 1000
        set_blest_rtt(0, da_us)
        set_blest_rtt(1, db_us)

    time.sleep(1)

    # iperf3 TCP test
    h2.cmd('iperf3 -s -D -p 5201')
    time.sleep(1)
    out = h1.cmd(f'iperf3 -c {h2.IP()} -t {DURATION} -p 5201 -J')
    try:
        d = json.loads(out)
        mbps = round(d['end']['sum_sent']['bits_per_second'] / 1e6, 2)
        retrans = d['end']['sum_sent'].get('retransmits', 0)
    except Exception:
        mbps = 0
        retrans = -1

    # ping test
    ping_out = h1.cmd(f'ping -c 10 {h2.IP()}')
    m = re.search(
        r'rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)',
        ping_out,
    )
    avg_rtt = float(m.group(2)) if m else -1

    # path stats
    stats = read_path_stats()

    h2.cmd('kill %iperf3 2>/dev/null')
    net.stop()

    results.append((label, mbps, avg_rtt, retrans))
    print(f"\n  >>> {label}: {mbps} Mbps, RTT {avg_rtt} ms, retransmits {retrans}")

# Summary
print(f"\n{'='*60}")
print("  SUMMARY")
print(f"{'='*60}")
print(f"{'Label':<30} {'Throughput':>12} {'RTT':>10} {'Retrans':>10}")
print('-' * 65)
for label, mbps, rtt, ret in results:
    print(f"{label:<30} {mbps:>10.2f} Mb {rtt:>8.1f} ms {ret:>10}")

# Save JSON
os.makedirs(os.path.expanduser('~/p4-simulation/results'), exist_ok=True)
out_path = os.path.expanduser('~/p4-simulation/results/summary.json')
with open(out_path, 'w') as f:
    json.dump(
        [
            {
                'label': l,
                'throughput_mbps': m,
                'avg_rtt_ms': r,
                'retransmits': t,
            }
            for l, m, r, t in results
        ],
        f,
        indent=2,
    )
print(f"\nSaved to {out_path}")
