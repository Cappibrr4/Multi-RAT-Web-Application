# Theory of Switch-Based Multipath Scheduling

## IS Group 8 — Multi-RAT Web Application
### Singapore Institute of Technology — ITP2

---

## 1. Problem Statement

Our Multi-RAT system implements 8 novel MPTCP schedulers (Hybrid, CWL, EDF, LRTT, BLEST, ECF, Round-Robin, Redundant) and MPQUIC support, all running as **endpoint software** on Linux machines. While this proves the scheduling algorithms work, it raises a practical deployment question:

> *"From the perspective of an end user, if this were to go on a switch, then the switch will have to run this logic. How can we insert the logic into a configurable Layer 3 switch?"*
> — Professor's feedback, 30 September 2026

This document presents the **theoretical framework** for deploying our multipath scheduling logic on programmable network switches, supported by existing research.

---

## 2. Background: Endpoint vs. Switch-Based Scheduling

### 2.1 Endpoint Scheduling (Current Implementation)

In our current system, the MPTCP kernel module on the **sender's machine** decides which subflow (network interface) carries each packet. The kernel scheduler (e.g., `sched_rr.c`) iterates over available subflows, checks their status, and marks one as "scheduled."

**Limitations:**
- Requires custom kernel on every endpoint
- Scheduling overhead runs in the OS kernel
- Every user must install and configure the MPTCP stack
- No centralized control or visibility

### 2.2 Switch-Based Scheduling (Proposed)

Instead of running scheduling logic on endpoints, we move it into the **network infrastructure** — specifically onto programmable Layer 3 switches. The switch distributes packets across multiple paths transparently, without requiring any changes to endpoint software.

**Advantages:**
- Zero endpoint overhead — applications are unmodified
- Centralized scheduling logic — single point of configuration
- Line-rate processing — hardware switches process at wire speed
- Service model — users consume multipath as a service via API

---

## 3. Enabling Technology: P4 Programmable Data Planes

### 3.1 What is P4?

P4 (Programming Protocol-independent Packet Processors) is a domain-specific language for programming the forwarding behavior of network switches. Unlike traditional switches with fixed forwarding pipelines, P4 switches let you define:

1. **Parser**: What headers to extract from packets
2. **Match-Action tables**: How to classify and process packets
3. **Registers/Counters**: Persistent state across packets (crucial for schedulers)
4. **Deparser**: How to reconstruct packets after processing

### 3.2 Why P4 Enables Our Schedulers

Our MPTCP schedulers require:
- **State** (which subflow was used last, RTT estimates, cwnd proxy) → P4 **registers**
- **Per-packet decisions** (which path to send on) → P4 **match-action tables**
- **Counters** (packets per path, utilization) → P4 **counters**
- **Arithmetic** (HoL prediction in BLEST) → P4 **arithmetic operations**

All of these are available in P4, making it theoretically possible to port every one of our 8 schedulers to the switch data plane.

### 3.3 Existing Research Proving Feasibility

| Paper | What It Proves | Year |
|-------|---------------|------|
| Motohashi et al., "Implementation of P4-Based Schedulers for Multipath Communications" (IEEE Access) | **Three multipath schedulers (Random, WRR, DWRR) running in P4 on BMv2.** Tested in Mininet-WiFi with UDP. Directly proves P4 can implement multipath scheduling. | 2022 |
| Katta et al., "HULA: Scalable Load Balancing Using Programmable Data Planes" (SOSR) | **Switch-native load balancing in P4.** Each switch probes congestion, picks best path. Written in P4 for programmable chips. | 2016 |
| MP-HULA | **Multipath extension of HULA for MPTCP.** HULA gave sub-optimal results with MPTCP; MP-HULA uses best-k paths per destination. Runs entirely on P4 switches. | 2018 |
| Raiciu et al., "Improving Datacenter Performance and Robustness with Multipath TCP" | **MPTCP at infrastructure level** in data centers. Proves multipath benefits at network scale. | 2011 |
| Pol et al., "Multipathing with MPTCP and OpenFlow" | **First work combining MPTCP with SDN/OpenFlow.** Path management on switches. | 2013 |

---

## 4. Architecture: Switch-Based Multipath Scheduler

### 4.1 System Architecture

```
                          ┌─────────────────────┐
                          │   SDN Controller     │
                          │  (Path monitoring,   │
                          │   RTT updates,       │
                          │   API endpoint)      │
                          └──────────┬──────────┘
                                     │ P4Runtime / Thrift
                          ┌──────────▼──────────┐
                          │   P4 Switch (S1)     │
                          │  ┌───────────────┐   │
     ┌──────┐             │  │ Multipath     │   │             ┌──────┐
     │ Host │─────────────│──│ Scheduler     │───│─── Path A ──│ Host │
     │ (H1) │             │  │ (RR/BLEST/    │   │             │ (H2) │
     └──────┘             │  │  ECF/etc.)    │───│─── Path B ──└──────┘
                          │  └───────────────┘   │
                          │  Registers:          │
                          │   - rr_index         │
                          │   - path_rtt[N]      │
                          │   - path_pkt_count   │
                          │   - lambda           │
                          └─────────────────────┘
```

### 4.2 Components

1. **P4 Data Plane (Switch)**: Runs the scheduling algorithm at line rate. Maintains registers for state (RR index, RTT estimates, counters). Makes per-packet forwarding decisions.

2. **SDN Controller**: Monitors path quality (RTT, loss, bandwidth). Updates switch registers with fresh measurements. Exposes an API for external configuration. Handles the "slow path" decisions that P4 can't.

3. **Developer API** (seller standpoint): REST/gRPC endpoint for users to select schedulers, configure paths, monitor performance. Users don't need to understand MPTCP internals.

### 4.3 Mapping Kernel Schedulers to P4

| Kernel Scheduler | P4 Implementation | Complexity |
|-----------------|-------------------|------------|
| **Round-Robin** (`sched_rr.c`) | Register-based index, `idx = (idx+1) % N_PATHS` | Low — direct translation |
| **LRTT** (`sched_lrtt.c`) | Read RTT registers, pick min. Controller probes RTT. | Medium |
| **BLEST** (`sched_blest.c`) | RTT registers + lambda register. HoL prediction via arithmetic. | Medium-High |
| **ECF** (`sched_ecf.c`) | Similar to BLEST — compare completion times across paths. | Medium-High |
| **CWL** (`sched_novelcwl.c`) | Congestion window proxy via packet counters. | Medium |
| **EDF** (`sched_noveledf.c`) | Deadline calculation from RTT + queue depth estimate. | High |
| **Redundant** (`sched_redundant.c`) | Clone packet to all paths (P4 `clone` primitive). | Low |
| **Hybrid** (`hybridsched.c`) | Combine RR + LRTT with mode register. | Medium |

---

## 5. Simulation Methodology

### 5.1 Simulation Environment

We validate our theory using **Mininet + BMv2 (P4 Behavioral Model)**, which is the standard academic approach for P4 research:

- **Mininet**: Creates virtual network topologies with real TCP/IP stacks
- **BMv2 (simple_switch)**: Software P4 switch — executes P4 programs identically to hardware
- **p4c**: P4 compiler that produces BMv2-compatible JSON
- **iperf3**: Generates TCP/UDP traffic for throughput measurement
- **simple_switch_CLI**: Runtime interface for reading counters and updating registers

### 5.2 Topology

```
                    ┌──── S2 (Path A: low delay) ────┐
   H1 ──── S1 ─────┤                                ├───── S4 ──── H2
                    └──── S3 (Path B: high delay) ───┘
```

- **S1**: Runs the P4 multipath scheduler (RR or BLEST)
- **S2/S3**: Relay switches with configurable delay, bandwidth, and loss
- **S4**: Merge switch — reassembles traffic toward destination
- **H1/H2**: Standard Linux hosts running iperf3

### 5.3 Test Scenarios

| Scenario | Path A | Path B | Purpose |
|----------|--------|--------|---------|
| Symmetric | 10ms, 10Mbps | 10ms, 10Mbps | Baseline — both paths equal |
| Asymmetric Delay | 10ms, 10Mbps | 50ms, 10Mbps | WiFi + wired — different RTT |
| WiFi vs LTE | 10ms, 20Mbps | 80ms, 5Mbps | Real-world heterogeneous access |
| Lossy | 10ms, 10Mbps, 1% loss | 30ms, 10Mbps, 5% loss | Wireless degradation |
| Extreme | 5ms, 50Mbps | 200ms, 2Mbps | Stress test — satellite + fiber |

### 5.4 Metrics

- **Throughput** (Mbps): Aggregate goodput across both paths
- **Latency** (ms): Average RTT from H1 to H2
- **Jitter** (ms): Variation in packet arrival times
- **Packet Loss** (%): End-to-end loss rate
- **Path Utilization Balance**: Ratio of packets on each path

### 5.5 Expected Results

Based on the Motohashi et al. (2022) findings and BLEST theory:

1. **Symmetric paths**: RR and BLEST should perform similarly, with RR achieving near-perfect 50/50 split
2. **Asymmetric paths**: BLEST should outperform RR by avoiding the slow path when HoL blocking is predicted, resulting in lower jitter and fewer retransmissions
3. **Extreme asymmetry**: RR will suffer significant reordering penalties; BLEST should adaptively use only the fast path
4. **All scenarios**: Switch-based scheduling eliminates endpoint CPU overhead for scheduling decisions

---

## 6. Thesis Argument

### 6.1 Core Claim

> Our MPTCP/MPQUIC scheduling algorithms, demonstrated to work on endpoints, can be deployed on programmable Layer 3 switches using P4 data-plane programming. This enables an as-a-service model where the switch handles multipath scheduling transparently, and developers interact through an API without needing to understand the underlying protocol mechanics.

### 6.2 Supporting Evidence

1. **Motohashi et al. (2022)** implemented three multipath schedulers in P4 and tested them in Mininet-WiFi, proving that packet scheduling can run on the switch data plane.

2. **MP-HULA (2018)** demonstrated MPTCP-aware load balancing running entirely on P4 switches in data center networks, proving that multipath transport awareness is feasible at the switch level.

3. **Our simulation** ports the Round-Robin and BLEST schedulers from our Linux kernel implementation to P4, running on BMv2 in Mininet, demonstrating a direct kernel-to-switch translation path.

4. **BLEST's HoL blocking prediction**, while requiring endpoint-side state (cwnd, in-flight) in the kernel, can be approximated on the switch using controller-provided RTT measurements and packet counters as proxies — maintaining the algorithm's core benefit with a slight loss in precision.

### 6.3 Limitations and Future Work

- **P4 arithmetic**: Fixed-point only — some scheduler formulas (EDF deadline, ECF completion time) need careful adaptation
- **State visibility**: Switches don't see TCP-level state (cwnd, ssthresh). The controller must provide estimates, or INT (In-band Network Telemetry) must be used
- **BMv2 vs. hardware**: BMv2 is cycle-accurate for logic but not for performance. Hardware P4 switches (Tofino, Intel IPU) process at line rate but have pipeline constraints
- **MPQUIC**: Requires additional work since QUIC is encrypted and the switch can't inspect transport headers without cooperation from the QUIC endpoint

---

## 7. References

1. H. Motohashi, P. L. Nguyen, K. Nguyen, H. Sekiya, "Implementation of P4-Based Schedulers for Multipath Communications," IEEE Access, vol. 10, pp. 76537-76546, 2022.

2. N. Katta, M. Hira, C. Kim, A. Sivaraman, J. Rexford, "HULA: Scalable Load Balancing Using Programmable Data Planes," ACM SOSR, 2016.

3. MP-HULA, "Multi-path HULA for MPTCP-aware Load Balancing," 2018.

4. C. Raiciu, S. Barre, C. Pluntke, A. Greenhalgh, D. Wischik, M. Handley, "Improving Datacenter Performance and Robustness with Multipath TCP," ACM SIGCOMM, 2011.

5. S. Ferlin, Ö. Alay, O. Mehani, R. Boreli, "BLEST: Blocking Estimation-based MPTCP Scheduler for Heterogeneous Networks," IFIP Networking, 2016.

6. Q. De Coninck, O. Bonaventure, "Multipath QUIC: A Deployable Multipath Transport Protocol," ACM CoNEXT, 2017.

7. J. Shu et al., "A Multipath Extension to the QUIC Module for ns-3," ACM WNS3, 2023.

8. M. Kheirkhah, I. Wakeman, G. Sheraton, "Multipath-TCP in ns-3," arXiv:1510.07721, 2015.

9. P. Pol et al., "Multipathing with MPTCP and OpenFlow," 2013.

10. Bonaventure et al., "Multipath schedulers," IETF Internet-Draft, draft-bonaventure-iccrg-schedulers, 2021.
