# P4 Switch Scheduling — Research Reference Guide

Oct 19, 2026 · @Adil

IS Group 8 · Multi-RAT Web Application · ITP2

## Source 1: Motohashi et al. (2022)

**Title:** Implementation of P4-Based Schedulers for Multipath Communications

**Published:** IEEE Access, vol. 10, pp. 76537–76546, 2022

**Authors:** Hiroaki Motohashi, Phi Le Nguyen, Kien Nguyen, Hiroo Sekiya (Chiba University)

**What it proves for us:** This is the strongest direct evidence that multipath scheduling can run on the switch data plane using P4. The authors implemented three schedulers — Random Splitting, Weighted Round Robin (WRR), and Dynamic Weighted Round Robin (DWRR) — as P4 programs running on BMv2 software switches in a Mininet-WiFi environment.

**Key findings:**

- DWRR dynamically adjusts path weights based on available bandwidth, similar to how our BLEST and ECF schedulers adapt to path conditions
- All three schedulers ran at the switch level with no modifications to endpoint software
- Tested with UDP traffic over heterogeneous wireless links
- The P4 register mechanism stores per-path state across packets, exactly what our RR and BLEST schedulers need

**How we cite it:** "Motohashi et al. proved that multipath packet schedulers can be implemented in P4 and executed on programmable switches, achieving path-aware forwarding without endpoint involvement. Our work extends this by porting MPTCP-specific schedulers (Round-Robin, BLEST) to P4, adding HoL blocking estimation to the switch data plane."

**Link:** [Chiba University Lab Page](https://www.s-lab.nd.chiba-u.jp/achievements/abst.php?paper=690)

## Source 2: Katta et al. (2016)

**Title:** HULA: Scalable Load Balancing Using Programmable Data Planes

**Published:** ACM Symposium on SDN Research (SOSR), 2016

**Authors:** Naga Katta, Mukesh Hira, Changhoon Kim, Anirudh Sivaraman, Jennifer Rexford (Princeton University)

**What it proves for us:** HULA is a load-balancing scheme written entirely in P4 that runs on the switch hardware itself — no controller in the forwarding path. Each switch uses in-band probe packets to track the best next-hop for each destination, storing congestion information in registers. This proves that per-path quality tracking (which our schedulers need) can live inside the switch.

**Key findings:**

- Switches autonomously discover best paths using periodic probe packets
- Path quality (congestion) is stored in P4 registers on each switch
- No controller involvement in the per-packet forwarding decision
- Written in P4 for Barefoot Tofino chips — runs at line rate in hardware
- Scales to data center topologies (fat-tree, Clos)

**How we cite it:** "Katta et al. demonstrated that network switches can autonomously track path quality and make forwarding decisions using P4 registers and probe packets, without controller involvement. This mechanism is directly applicable to our schedulers: the switch can maintain RTT and utilization estimates per path, enabling BLEST-style HoL prediction at line rate."

**Link:** [Princeton CS](https://www.cs.princeton.edu/~jrex/talks/hula16.pdf) · [ACM DL](https://dx.doi.org/10.1145/2890955.2890968)

## Source 3: MP-HULA (2018)

**Title:** MP-HULA: Multipath HULA for MPTCP-aware Load Balancing

**Published:** 2018 (extension of HULA; referenced in P4 surveys and P4.org webinars)

**What it proves for us:** This is the most directly relevant paper. MP-HULA was created because the original HULA gave sub-optimal results when used with MPTCP — it would pin multiple subflows of the same MPTCP connection onto the same bottleneck link. MP-HULA fixes this by tracking the best-k paths (not just the single best) per destination, spreading MPTCP subflows across distinct paths.

**Key findings:**

- Original HULA fails with MPTCP because it picks ONE best path — all subflows converge on that path
- MP-HULA uses best-k paths per destination, distributing subflows across them
- Runs entirely on P4 switches in the data plane — no endpoint changes
- Outperforms both ECMP and single-path HULA for MPTCP workloads in data centers
- Proves that MPTCP-aware scheduling logic belongs on the switch, not just the endpoint

**How we cite it:** "MP-HULA directly proves that MPTCP-aware scheduling logic can and should run on P4 switches. The failure of single-best-path HULA with MPTCP mirrors the problem our thesis addresses: endpoint-only scheduling misses network-level path diversity. MP-HULA’s best-k approach is conceptually aligned with our BLEST scheduler’s HoL avoidance — both prevent subflow clustering on congested paths."

**Link:** [P4.org Webinar (HULA and MP-HULA)](https://hhk3.kau.se/dpp/wp-content/uploads/sites/19/2021/04/DVAD42-P4Exercise2-Webinar_3_final-compressed.pdf)

## Source 4: Raiciu et al. (2011)

**Title:** Improving Datacenter Performance and Robustness with Multipath TCP

**Published:** ACM SIGCOMM, 2011

**Authors:** Costin Raiciu, Sebastien Barre, Christopher Pluntke, Adam Greenhalgh, Damon Wischik, Mark Handley (UCL London)

**What it proves for us:** This is the foundational paper that proves multipath TCP provides real benefits at infrastructure scale. Raiciu et al. showed that single-path TCP cannot fully utilize data center network capacity for certain topologies and traffic patterns, while MPTCP can. This is the "why multipath matters" paper that justifies the entire project.

**Key findings:**

- Single-path TCP wastes capacity in multi-rooted topologies (fat-tree, VL2, BCube)
- MPTCP achieves near-optimal throughput by spreading traffic across available paths
- Benefits are greatest when path diversity exists but single-path routing can’t exploit it
- Proved with real Linux MPTCP kernel implementation in a data center testbed
- The paper argues the network should expose path diversity to endpoints — our thesis takes the next step: the network itself can do the scheduling

**How we cite it:** "Raiciu et al. established that multipath transport provides measurable throughput and robustness gains at infrastructure scale. Our work builds on this foundation: where Raiciu argued endpoints should exploit path diversity via MPTCP, we demonstrate that the scheduling decision itself can be pushed into the network infrastructure via P4 programmable switches, eliminating the need for custom endpoint kernels."

**Link:** [UCL Publication](https://inl.info.ucl.ac.be/system/files/a10-raiciu.pdf)

## Source 5: Ferlin et al. (2016)

**Title:** BLEST: Blocking Estimation-based MPTCP Scheduler for Heterogeneous Networks

**Published:** IFIP Networking Conference, 2016

**Authors:** Simone Ferlin, Özgü Alay, Olivier Mehani, Roksana Boreli

**What it proves for us:** BLEST is one of our 8 implemented schedulers. This is the original paper describing its algorithm. BLEST solves Head-of-Line (HoL) blocking — when packets sent on a slow path cause the receiver to stall waiting for reordering. The algorithm predicts whether sending on a slower subflow will cause blocking, and holds back if so.

**Key findings:**

- HoL blocking is the main performance killer in heterogeneous multipath networks (e.g., WiFi + LTE)
- BLEST predicts blocking using: X = cwnd\_fast × (rtt\_slow − rtt\_fast) / rtt\_fast × λ
- If packets in-flight on the slow path exceed X, that path is skipped
- Lambda (λ) adapts over time based on retransmission signals
- Outperforms Round-Robin and MinRTT on asymmetric paths

**How we cite it:** "Our P4 implementation of BLEST (multipath\_blest.p4) translates the core HoL prediction to the switch data plane. While the switch lacks direct access to TCP cwnd and in-flight counts, we use controller-provided RTT measurements and packet counters as proxies. The lambda adaptation mechanism is maintained in P4 registers, preserving BLEST’s adaptive behavior."

**Link:** [ResearchGate](https://www.researchgate.net/publication/327122884)

## Source 6: De Coninck & Bonaventure (2017)

**Title:** Multipath QUIC: A Deployable Multipath Transport Protocol

**Published:** ACM CoNEXT, 2017

**Authors:** Quentin De Coninck, Olivier Bonaventure (UCLouvain, Belgium)

**What it proves for us:** This is the foundational MPQUIC paper — it extends QUIC (Google’s UDP-based transport) with multipath support. Since our project supports both MPTCP and MPQUIC, this paper justifies the MPQUIC side. It also highlights a key challenge for switch-based scheduling: QUIC encrypts its transport headers, making it harder for switches to inspect.

**Key findings:**

- MPQUIC is implemented entirely in userspace (Go), unlike MPTCP which needs kernel support
- MPQUIC achieves similar multipath benefits to MPTCP but is deployable without OS modifications
- The stream-aware design avoids some HoL blocking issues that MPTCP faces at the TCP layer
- Encryption of QUIC headers means switches cannot easily inspect transport state
- This creates a trade-off: switch-based scheduling for MPQUIC requires cooperation from the endpoint (e.g., exposing path hints in unencrypted fields)

**How we cite it:** "De Coninck and Bonaventure’s MPQUIC demonstrates that multipath transport can be deployed without kernel changes. For our switch-based scheduling model, MPQUIC presents both an opportunity (userspace deployment aligns with the API/service model) and a challenge (encrypted headers limit switch visibility). Our API design addresses this by providing path configuration to MPQUIC endpoints, while the switch handles the underlying path selection."

**Link:** [ResearchGate](https://www.researchgate.net/publication/327122884_Multipath_QUIC_A_Deployable_Multipath_Transport_Protocol)

## Source 7: Pol et al. (2013)

**Title:** Multipathing with MPTCP and OpenFlow

**Published:** 2013

**What it proves for us:** This was the first published work combining MPTCP with SDN (Software-Defined Networking) via OpenFlow. It showed that an SDN controller can manage MPTCP subflow paths — instead of letting the OS pick paths, the controller installs flow rules on OpenFlow switches to route each subflow through a specific path.

**Key findings:**

- SDN controllers can see all subflows of an MPTCP connection and route them independently
- OpenFlow flow rules can pin specific subflows to specific paths through the network
- The controller has a global view of network topology and congestion, which endpoints lack
- This combination outperforms endpoint-only path selection in topologies with path diversity
- Tested with Mininet and the Floodlight/Ryu SDN controllers

**How we cite it:** "Pol et al. established the feasibility of SDN-managed MPTCP subflow routing via OpenFlow. Our work extends this from flow-level path assignment (controller decides which path each subflow takes) to packet-level scheduling (the P4 switch decides per-packet, using RR or BLEST logic). This is a finer-grained control that enables adaptive scheduling without controller-per-packet involvement."

**Link:** [ResearchGate](https://www.researchgate.net/publication/261078394_Multipathing_with_MPTCP_and_open_flow)

## Source 8: Bonaventure et al. (2021)

**Title:** Multipath Schedulers (IETF Internet-Draft)

**Published:** IETF, draft-bonaventure-iccrg-schedulers, October 2021

**Authors:** Olivier Bonaventure et al.

**What it proves for us:** This IETF draft is a comprehensive taxonomy of all known multipath schedulers. It classifies schedulers by their decision criteria (RTT-based, loss-based, redundancy-based) and compares their trade-offs. Having an IETF standards-track document validates that multipath scheduling is a recognized, active area of protocol engineering — not a fringe research topic.

**Key findings:**

- Classifies schedulers into categories: Round-Robin, Lowest-RTT, Redundant, Blocking-aware (BLEST, ECF), and Machine-Learning based
- Documents the trade-offs each scheduler makes (throughput vs. latency vs. reliability)
- Notes that scheduler choice depends on application requirements and path characteristics
- Discusses both MPTCP and MPQUIC schedulers in a unified framework
- Explicitly mentions BLEST, ECF, and Round-Robin — three of our eight implemented schedulers

**How we cite it:** "The IETF draft by Bonaventure et al. provides the authoritative taxonomy of multipath schedulers. Our 8 kernel-space schedulers cover multiple categories from this taxonomy. Our P4 switch implementation demonstrates that these categories are not limited to endpoint execution — the same algorithmic decisions can be made at the switch data plane."

**Link:** [IETF Datatracker](https://datatracker.ietf.org/doc/html/draft-bonaventure-iccrg-schedulers)

## How These Sources Chain Together

The evidence builds in layers: multipath transport works at scale (Raiciu), smart schedulers solve its key problem of HoL blocking (Ferlin/BLEST), switches can track path quality autonomously (HULA), and multipath schedulers specifically have been implemented in P4 (Motohashi, MP-HULA). Our thesis sits at the top of this chain: porting our 8 schedulers to P4 and proving it with simulation.

The bottom two layers are established research. The "Direct Proof" layer is where our thesis draws its strongest support — Motohashi and MP-HULA each independently proved that multipath scheduling logic can run on P4 switches. Our contribution extends their work by porting MPTCP-specific scheduling algorithms (including BLEST’s adaptive HoL prediction) to the switch data plane and validating them with Mininet + BMv2.
