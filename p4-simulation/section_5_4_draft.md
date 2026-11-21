## Theoretical Study of Multipath Logic on Network Devices

In all the work described so far, the multipath scheduling decision — which path carries each packet — is made on the end host. For MPTCP, the kernel scheduler runs on the sender; for MP-QUIC, the user-space library on the sender does the same. This means every machine that wants multipath must be provisioned with the stack and configured correctly, which is feasible for a handful of workstations but does not scale to an entire vessel carrying dozens of passenger devices, CCTV cameras, IoT sensors and crew laptops. If the scheduling logic could instead run on a network device sitting between the ship's LAN and its uplinks, every device behind it would benefit from multipath transport without any per-device configuration. This section investigates, in theory, whether such a deployment is feasible, what form it would take and what its limitations are.

### *Existing In-Network Multipath Approaches*

Section 2.6 introduced four classes of in-network multipath that are already deployed or standardised. OpenMPTCProuter [1] runs the full MPTCP kernel stack on an OpenWrt router and tunnels client traffic through a VPS, bonding up to eight WAN links transparently. The IETF 0-RTT TCP Convert Protocol [2] specifies transport converters — middleboxes that upgrade a client's plain TCP connection to MPTCP on the network side, so that legacy applications gain multipath without modification. Hybrid Access Networks [3] use a similar principle at the access layer, bonding fixed and cellular links between a customer-premises gateway and an operator aggregation point. In the 5G architecture, Access Traffic Steering, Switching and Splitting (ATSSS) [24] places MPTCP and MP-QUIC proxy functions in the User Plane Function, splitting traffic across 3GPP and non-3GPP access.

All four approaches move the multipath termination point into the network, confirming that the concept is viable. However, they share a limitation: they use generic schedulers (typically lowest-RTT or round-robin) designed for terrestrial fixed and cellular access. None of them incorporates heterogeneity-aware schedulers such as BLEST [9] or ECF [10], which were shown in ITP1 to outperform the defaults on links resembling maritime conditions. The question this study asks is therefore not whether multipath can run on a network device — it demonstrably can — but whether the specific scheduling algorithms developed in this project could do so.

### *Candidate Deployment Points on a Vessel*

Three locations in a vessel's on-board network could host the scheduling logic, each with different trade-offs.

Multipath gateway (software, general-purpose CPU). A Linux machine or router running the MPTCP kernel, positioned between the ship's LAN and the satellite and cellular uplinks. This is the approach taken by OpenMPTCProuter [1]. It requires no special hardware: any x86 or ARM device running the project's patched kernel can serve as the gateway. The drawback is that the scheduling runs in the kernel on a general-purpose CPU, adding per-packet latency proportional to the scheduler's complexity and consuming CPU cycles that could otherwise serve other functions. On a busy vessel LAN with throughput in the hundreds of megabits, this overhead may become significant.

Transport converter (proxy). A middlebox implementing the Convert Protocol [2] or a similar proxy. It terminates the client's TCP connection and re-originates it as MPTCP toward the uplinks. This preserves full compatibility with unmodified clients but introduces an extra TCP hop, doubling the connection setup time and adding a point of failure. Because the converter sees TCP state (congestion window, in-flight bytes), it has access to the same information the kernel schedulers use, so any of the ITP1 schedulers could in principle run here without approximation.

Programmable Layer 3 switch (hardware data plane). A switch whose forwarding pipeline can be programmed to execute the scheduling logic directly in the data plane, making the per-packet decision at wire speed rather than in software. This is the option the remainder of this section explores, because it offers the lowest latency, the highest throughput and zero CPU overhead — all desirable properties for an always-on network device on a vessel.

### *Enabling Technology: P4 Programmable Data Planes*

Traditional switches have fixed forwarding pipelines: they can match on destination MAC or IP and forward to a port, but they cannot be told to keep state across packets or to run custom arithmetic on header fields. P4 (Programming Protocol-independent Packet Processors) [25] is a domain-specific language that removes this limitation. A P4 program defines four things: a parser that extracts headers, match-action tables that classify and process packets, registers and counters that persist state across packets and a deparser that reassembles the packet before it leaves the switch. P4 programs compile to both software switches (BMv2 [26]) and commercial hardware targets (Intel Tofino, AMD Memory-Centric Smartnets).

P4 provides exactly the primitives the ITP1 schedulers need. A round-robin index is a single register incremented modulo the number of paths. Per-path RTT estimates and packet counts map to register arrays. BLEST's head-of-line blocking prediction requires comparing a scaled delay difference against a threshold, which is fixed-point arithmetic that P4 supports. The one constraint is that P4 has no division operator, because division cannot be implemented in a single pipeline stage at line rate; any formula that divides must be rewritten using bit shifts (right-shift by 10 approximates division by 1024, close enough to division by 1000 for millisecond-scale values) or by rearranging the inequality to use multiplication instead (testing whether a/b > 3 becomes a > 3b).

Motohashi et al. [27] proved this feasibility directly. They implemented three multipath schedulers — Random, Weighted Round-Robin and Deficit Weighted Round-Robin — in P4 and tested them on BMv2 in a Mininet-WiFi topology. Their experiments showed that the P4 schedulers produced the same traffic distribution as equivalent kernel-space implementations, confirming that the switch data plane can make per-packet multipath scheduling decisions. Katta et al. [28] demonstrated a related concept with HULA, a P4 program in which every switch in a data-centre fabric probes path congestion and independently selects the least-loaded next hop, achieving load balancing entirely in the data plane without a central controller.

### *Proposed Design: P4 Switch as the Multipath Scheduler*

The proposed architecture places a P4-programmable switch at the vessel's network edge, where it connects the on-board LAN to two or more uplinks (for example, satellite on one port and cellular on another). The switch inspects each outgoing packet's destination, and for prefixes that should be multipath-scheduled, it runs the scheduling algorithm in the data plane and forwards the packet to the selected egress port.

The design has three components. The first is the P4 data plane on the switch itself. The P4 program parses Ethernet and IPv4 headers, looks up the destination in a multipath routing table and, on a match, executes the scheduler action. The scheduler reads per-path state from registers (RTT estimates, packet counts, a round-robin index, the BLEST lambda parameter), makes the forwarding decision and writes updated state back. Packets that do not match the multipath table fall through to a standard longest-prefix-match forwarding table.

The second component is the controller, a software process running off the data plane. It monitors path quality by sending periodic probes through each uplink and measuring the round-trip time, then writes the measurements into the switch's RTT registers. The controller also exposes a configuration interface through which an operator or the dashboard can select the active scheduler, adjust parameters or read per-path statistics. Communication between the controller and the switch uses the switch's runtime interface (Thrift CLI for BMv2, P4Runtime for hardware targets).

The third component is the set of unmodified end hosts. Devices on the vessel's LAN send ordinary TCP or UDP traffic. The switch handles path selection transparently. The end hosts do not need MPTCP, MP-QUIC or any special configuration. This is the key advantage over the endpoint-based deployment described in the rest of this report: the scheduling logic runs once, on the switch, rather than on every device.

*[Insert architecture figure: SDN controller at top, P4 switch (S1) in the centre with registers listed, Host (H1) on the left connected to the switch, two egress paths (Path A and Path B) on the right leading to Host (H2). Figure caption below the image, Times New Roman 11pt bold.]*

Figure X: Proposed architecture for switch-based multipath scheduling

Table X maps each of the ITP1 kernel schedulers to its P4 equivalent and rates the translation complexity.

Table X: Mapping of ITP1 kernel schedulers to P4 switch equivalents

| Kernel Scheduler | P4 Equivalent | Complexity | Notes |
|---|---|---|---|
| Round-Robin (sched_rr) | Register index, idx = (idx+1) % N | Low | Direct translation; no arithmetic beyond modulo |
| LRTT (sched_lrtt) | Read RTT registers, pick minimum | Medium | Controller must populate RTT registers |
| BLEST (sched_blest) | RTT registers + lambda register; HoL prediction via bit-shift arithmetic | Medium-High | Division replaced by >> 10; ratio test by multiply-compare |
| ECF (sched_ecf) | Similar to BLEST: compare completion-time estimates per path | Medium-High | Requires estimated bandwidth per path |
| Redundant (sched_redundant) | P4 clone primitive sends packet to all egress ports | Low | Direct use of the clone extern |
| Hybrid (hybridsched) | Mode register selects between RR and LRTT actions | Medium | Combines two simpler schedulers |

The main constraint is that the switch cannot see TCP-level state such as the congestion window or the number of bytes in flight, because these exist only inside the endpoint's kernel. BLEST's original formula, X = cwnd_fast x (rtt_slow - rtt_fast) / rtt_fast x lambda, depends on cwnd. On the switch, the controller substitutes a proxy: the per-path packet count over a recent interval, which correlates with the congestion window under steady-state conditions. This is an approximation, not an exact replacement, and it means the switch-based BLEST may react more slowly to sudden congestion-window changes than the kernel version. For the maritime use case, where link conditions change on the scale of seconds to minutes rather than milliseconds, this approximation is acceptable.

### *Feasibility Validation through Simulation*

To confirm that the proposed design is not merely theoretical, a proof-of-concept simulation was built using the standard academic toolchain for P4 research: Mininet for network emulation, BMv2 (simple_switch) as the software P4 target and p4c as the compiler [26]. Two schedulers were ported from their kernel C implementations to P4_16: Round-Robin and BLEST, chosen because they represent the simplest and one of the most complex schedulers respectively.

The simulation topology mirrors the proposed vessel deployment. Host H1 connects to the ingress switch S1, which runs the P4 multipath scheduler. S1 has two egress ports leading to relay switches S2 (Path A) and S3 (Path B), which merge at egress switch S4 before reaching Host H2. On the relay switches, tc netem configures per-path delay, bandwidth and loss to simulate heterogeneous uplinks. The test scenario models a vessel with a low-latency link (Path A: 10 ms RTT, 20 Mbps) and a high-latency link (Path B: 80 ms RTT, 5 Mbps), representative of a combined satellite-and-cellular setup.

*[Insert topology figure: H1 -- S1 branches to S2 (Path A) and S3 (Path B), both merge at S4 -- H2. Figure caption below the image, Times New Roman 11pt bold.]*

Figure X: Mininet simulation topology for the P4 switch scheduling proof of concept

Under these asymmetric conditions, the Round-Robin scheduler on the switch achieved only 0.24 Mbps aggregate throughput. Because RR sends every other packet onto the 80 ms path, the receiver stalls waiting for reordering, and TCP's congestion control throttles the sender — the classic head-of-line blocking problem that BLEST was designed to solve. The BLEST scheduler on the switch, with its RTT registers populated by the controller to reflect the 10 ms and 80 ms path delays, achieved 19.22 Mbps — an 80-fold improvement. BLEST's scaled delay comparison detected that the slow path would cause HoL blocking and routed traffic predominantly through the fast path, exactly as the kernel-space BLEST does on an endpoint. On the symmetric scenario (both paths 10 ms, 10 Mbps) the two schedulers performed comparably at 22.93 Mbps (RR) and 21.98 Mbps (BLEST), confirming that the difference emerges only under path heterogeneity.

This result validates the core claim: the scheduling algorithms developed in this project can run on a programmable switch data plane and produce the same qualitative behaviour as their kernel counterparts. The P4 source code for both schedulers, the Mininet topology and the benchmark scripts are included in the project repository under p4-simulation/.

### *Limitations and Future Work*

Several limitations apply to this theoretical study and its proof-of-concept simulation.

First, BMv2 is a software model. It executes P4 programs with the same logic as a hardware switch but not at hardware speed; the throughput figures above reflect Mininet's virtual links, not line-rate forwarding. Validating performance on a hardware P4 target (such as an Intel Tofino switch) is left as future work.

Second, the switch-based scheduler works alongside, not instead of, MPTCP or MP-QUIC on the endpoints when those protocols are present. The switch handles path selection; the transport protocol on the endpoint still handles subflow management, sequence numbering and retransmission. For unmodified endpoints running plain TCP, the switch provides the multipath benefit transparently; for endpoints already running MPTCP, the switch and the endpoint scheduler would need coordination to avoid conflicting decisions, which this study does not address.

Third, P4's lack of a division operator means that any scheduler formula involving division must be approximated. The bit-shift and multiply-compare techniques used here introduce small numerical errors (right-shifting by 10 divides by 1024 rather than 1000, a 2.4% error). For the RTT-scale values involved in BLEST's threshold comparison, this is negligible, but schedulers with tighter numerical requirements (for example, EDF's deadline calculation) would need more careful fixed-point analysis.

Fourth, MP-QUIC poses an additional challenge. QUIC encrypts its transport headers, so a switch cannot inspect the connection ID, stream state or congestion feedback without cooperation from the endpoint. A future design could use QUIC's Spin Bit [29] to estimate RTT at the switch without decryption, but fine-grained scheduling of MP-QUIC subflows from the switch remains an open problem.

Despite these limitations, the study demonstrates that moving multipath scheduling from the endpoint to a programmable network device is feasible in principle and produces the expected performance differentiation between schedulers. For a vessel deployment, a P4-capable switch or SmartNIC at the network edge could serve every on-board device with heterogeneity-aware multipath scheduling, eliminating the need to provision each machine individually.


---

New references to add after [24] in the REFERENCES section:

[25] Bosshart P, Daly D, Gibb G, Izzard M, McKeown N, Rexford J, et al. P4: programming protocol-independent packet processors. ACM SIGCOMM Comput Commun Rev. 2014; 44(3):87-95. doi:10.1145/2656877.2656890

[26] P4 Language Consortium. Behavioral Model (BMv2) [Internet]. GitHub; [cited 2026 Nov 15]. Available from: https://github.com/p4lang/behavioral-model

[27] Motohashi H, Nguyen PL, Nguyen K, Sekiya H. Implementation of P4-based schedulers for multipath communications. IEEE Access. 2022; 10:76537-46. doi:10.1109/ACCESS.2022.3192527

[28] Katta N, Hira M, Kim C, Sivaraman A, Rexford J. HULA: scalable load balancing using programmable data planes. In: Proceedings of the Symposium on SDN Research (SOSR '16). New York: ACM; 2016. p. 10:1-10:12. doi:10.1145/2890955.2890968

[29] De Vaere P, Buhler T, Olveczky BP, Trammell B. Three bits suffice: explicit support for passive measurement of Internet latency in QUIC and TCP. In: Proceedings of the Internet Measurement Conference (IMC '20). New York: ACM; 2020. p. 22-8. doi:10.1145/3419394.3423642
