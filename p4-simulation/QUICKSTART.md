# P4 Multipath Scheduler Simulation — Quick Start

## Prerequisites
- Ubuntu 22.04 or 24.04 LTS VM (the same one you use for Multi-RAT)
- At least 4GB RAM, 20GB disk space
- Root access

## Step 1: Install P4 Environment

```bash
cd ~/p4-simulation/scripts
sudo bash install_p4_env.sh
```

This installs Mininet, BMv2 (P4 software switch), and p4c (P4 compiler).
Takes ~30-60 minutes on first run.

## Step 2: Compile the P4 Programs

```bash
# Round-Robin scheduler
p4c --target bmv2 --arch v1model \
    -o /tmp/p4out_rr \
    ~/p4-simulation/p4src/multipath_rr.p4

# BLEST scheduler
p4c --target bmv2 --arch v1model \
    -o /tmp/p4out_blest \
    ~/p4-simulation/p4src/multipath_blest.p4
```

## Step 3: Run a Quick Test

```bash
# Test with Round-Robin, symmetric paths, drops into Mininet CLI
sudo python3 ~/p4-simulation/topology/multipath_topo.py \
    --scheduler rr --delay-a 10ms --delay-b 10ms --cli

# Inside Mininet CLI:
mininet> h1 ping h2 -c 10
mininet> h1 iperf3 -c 10.0.2.1 -t 10
mininet> exit
```

## Step 4: Test BLEST with Asymmetric Paths

```bash
# WiFi (10ms) vs LTE (80ms) scenario
sudo python3 ~/p4-simulation/topology/multipath_topo.py \
    --scheduler blest --delay-a 10ms --delay-b 80ms \
    --bw-a 20 --bw-b 5 --cli

# Inside CLI, run iperf and observe how BLEST avoids the slow path:
mininet> h2 iperf3 -s -D
mininet> h1 iperf3 -c 10.0.2.1 -t 30
mininet> exit
```

## Step 5: Run Full Benchmark

```bash
sudo bash ~/p4-simulation/scripts/run_benchmark.sh --duration 30

# Generate charts
python3 ~/p4-simulation/scripts/plot_results.py
```

## Step 6: Monitor BLEST in Real-Time

While the topology is running with `--cli`:

```bash
# In another terminal:
sudo python3 ~/p4-simulation/scripts/blest_controller.py --interval 2
```

## Step 7: Change RTT Mid-Test

Simulate a path degrading (e.g., LTE congestion):

```bash
# In another terminal while topology is running:
# Set Path B RTT to 200ms (was 80ms)
simple_switch_CLI --thrift-port 9090 <<< "register_write path_rtt 1 200000"
```

Watch how BLEST adapts by shifting traffic away from Path B.

## File Structure

```
p4-simulation/
├── p4src/
│   ├── multipath_rr.p4       # Round-Robin scheduler in P4
│   └── multipath_blest.p4    # BLEST scheduler in P4
├── topology/
│   └── multipath_topo.py     # Mininet topology with BMv2 switches
├── scripts/
│   ├── install_p4_env.sh     # One-shot environment setup
│   ├── run_benchmark.sh      # Full benchmark suite
│   ├── plot_results.py       # Results visualization
│   └── blest_controller.py   # BLEST RTT controller
├── results/                   # Benchmark output (JSON + charts)
├── THEORY.md                  # Theory writeup with research citations
└── QUICKSTART.md              # This file
```

## What This Proves

Running these simulations demonstrates that:

1. **Your MPTCP schedulers can run on switches** — the P4 programs implement
   the same logic as your kernel modules (`sched_rr.c`, `sched_blest.c`)
2. **No endpoint changes needed** — H1 and H2 are standard Linux hosts
3. **BLEST adapts to path asymmetry** — it avoids the slow path when HoL
   blocking is predicted, just like the kernel version
4. **This enables the "seller standpoint"** — the switch does the scheduling,
   the user just connects

## Presenting to Professor

Key points to highlight:

1. Show the **P4 code** (`multipath_rr.p4`) side-by-side with the **kernel code** (`sched_rr.c`) — same logic, different execution environment
2. Run the **symmetric test** — show 50/50 traffic split
3. Run the **asymmetric test** — show BLEST adapting
4. Show the **THEORY.md** research citations — Motohashi 2022, MP-HULA 2018
5. Explain: *"This is the same scheduling algorithm, but now it runs on the switch at line rate, and the end user doesn't need to install anything"*
