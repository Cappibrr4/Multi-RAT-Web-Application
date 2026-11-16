## Sea Trial Test Setup and Methodology

The sea trial was conducted over two days on a public ferry operating out of Marina South Pier (MSP) in Singapore, following a route through the Southern Islands: MSP to Lazarus Island (LAZ), Lazarus to Sisters Island (SIS) and Sisters Island back to MSP. Day 1 (5 November 2026) tested the six MPTCP schedulers; Day 2 (9 November 2026) tested the four MP-QUIC strategies. On the second day the ferry followed a slightly different route, passing through Kusu Island (KUSU) instead of Sisters Island on the return leg, giving route segments MSP–LAZ, LAZ–KUSU and KUSU–MSP. Two laptops were used, each connected to the internet through two mobile phone data hotspots (one phone per path) to give the multipath stacks two physically independent cellular uplinks to the remote iperf3 server hosted in Singapore.

At each route segment, purpose-built shell scripts ran a ping test followed by repeated 180-second iperf3 runs until the ferry docked. The MPTCP script used mptcpize to wrap iperf3 over the kernel MPTCP stack, while the MP-QUIC script used the Go-based mp-quic iperf client from the project repository. A companion Python script (get_results.py) post-processed the raw logs into CSV files covering aggregate throughput, per-run statistics, per-second intervals and per-subflow packet counts. Two schedulers were tested per route segment on each laptop, running concurrently, and the schedulers were rotated across segments so that every scheduler was tested on at least two segments of the route.


---


### *Sea Trial Results*

The sea trial produced substantially lower and more variable throughput than the lab baseline, which was expected given the uncontrolled nature of mobile hotspot connectivity on a moving vessel. Table X summarises the aggregate results for each MPTCP scheduler and each MP-QUIC strategy across all route segments tested.

Table X: MPTCP sea trial results — aggregate throughput and latency per scheduler

| Scheduler | Route Segments | Throughput (Mbps) | Run Mean (Mbps) | Run Stdev (Mbps) | Ping Avg (ms) | Ping P95 (ms) | Retransmits/min | Stall % |
|---|---|---|---|---|---|---|---|---|
| Default | MSP-LAZ, LAZ-SIS, SIS-MSP | 2.10–3.03 | 1.97–2.97 | 1.25–2.10 | 110–184 | 248–636 | 75–190 | 69–77 |
| LRTT | MSP-LAZ, LAZ-SIS, SIS-MSP | 1.89–4.32 | 1.82–4.31 | 0.23–3.09 | 44–80 | 63–355 | 24–119 | 74–83 |
| CWL | MSP-LAZ, LAZ-SIS, SIS-MSP | 1.71–4.15 | 1.94–3.88 | 0.74–4.27 | 35–74 | 169–335 | 6–32 | 69–81 |
| EDF | MSP-LAZ, LAZ-MSP | 4.08–5.08 | 3.82–5.12 | 2.41–2.58 | 52–74 | 84–243 | 4–57 | 63–73 |
| Hybrid | MSP-LAZ, LAZ-MSP | 4.02–4.06 | 3.87–4.05 | 1.76–1.94 | 88–443 | 231–1310 | 52–66 | 70–74 |
| Redundant | MSP-LAZ, LAZ-SIS, SIS-MSP | 0.59–1.99 | 0.30–1.80 | 0.42–1.15 | 78–124 | 191–472 | 7–105 | 73–76 |

For MPTCP, the EDF scheduler achieved the highest throughput on the sea trial, reaching 5.08 Mbps on the MSP–LAZ segment, followed by LRTT at 4.32 Mbps and CWL at 4.15 Mbps on the same segment. The default scheduler and the redundant scheduler consistently produced the lowest throughput, with redundant dropping as low as 0.59 Mbps on the LAZ–SIS segment. Stall percentages were high across all schedulers, ranging from 63% to 83%, indicating that for the majority of each one-second interval the connection was idle or stalled waiting for retransmissions. Retransmission rates varied widely: CWL had the lowest at 6 retransmits per minute on the LAZ–SIS segment, while default reached 190 retransmits per minute on SIS–MSP.

Ping latency was also much higher and more variable than in the lab. Average RTT ranged from 35 ms (CWL on MSP–LAZ) to 443 ms (Hybrid on LAZ–MSP), and the 95th percentile exceeded 300 ms for most schedulers on at least one segment. The hybrid scheduler exhibited the worst latency, with an average of 443 ms and a 95th percentile of 1310 ms on the LAZ–MSP segment, suggesting that its mode-switching logic struggled with the rapidly changing path quality.

Table X: MP-QUIC sea trial results — aggregate throughput and latency per strategy

| Strategy | Route Segments | Throughput (Mbps) | Run Mean (Mbps) | Run Stdev (Mbps) | Ping Avg (ms) | Ping P95 (ms) | Retransmits/min | Ping Loss % |
|---|---|---|---|---|---|---|---|---|
| BWA | MSP-LAZ, LAZ-MSP | 5.08–5.29 | 4.59–4.79 | 1.60–2.05 | 41–168 | 91–575 | 451–589 | 0 |
| BWLS | MSP-LAZ, LAZ-KUSU, KUSU-MSP | 4.28–7.46 | 4.19–6.29 | 1.82–3.43 | 118–477 | 714–1645 | 205–345 | 0 |
| LRTT | MSP-LAZ, LAZ-MSP | 7.00–7.42 | 5.89–8.58 | 3.08–3.64 | 46–488 | 95–3135 | 297–413 | 0 |
| RR | MSP-LAZ, LAZ-KUSU, KUSU-MSP | 3.42–6.91 | 2.47–5.53 | 2.02–4.45 | 59–522 | 100–1502 | 207–525 | 0–95 |

For MP-QUIC, the LRTT strategy achieved the highest throughput at 7.42 Mbps on the LAZ–MSP segment, with a run mean of 8.58 Mbps and individual runs peaking at 15.87 Mbps. BWLS reached 7.46 Mbps on the KUSU–MSP segment but with high variance (stdev 3.43 Mbps). BWA was the most consistent, with throughput between 5.08 and 5.29 Mbps across both segments and the lowest variance. RR had the widest spread, with throughput as low as 3.42 Mbps on LAZ–KUSU and as high as 6.91 Mbps on MSP–LAZ; critically, RR experienced 95% ping loss on two segments (LAZ–KUSU and KUSU–MSP), indicating severe connectivity disruption on those legs.

Retransmission rates for MP-QUIC were an order of magnitude higher than for MPTCP, ranging from 205 to 589 retransmits per minute. This is partly because MP-QUIC reports retransmissions at the QUIC layer rather than at the kernel TCP layer, so retransmits include QUIC-level recovery that would be invisible to the TCP-based measurement, and partly because the second test day (9 November) had rain, which degraded the mobile hotspot signal further.

Overall, MP-QUIC strategies achieved higher absolute throughput than MPTCP schedulers on the sea trial (5–7 Mbps versus 2–5 Mbps), but also exhibited higher retransmission rates and more volatile latency. The difference must be interpreted cautiously because the two protocols were tested on different days with different weather conditions: Day 1 (MPTCP) was clear, while Day 2 (MP-QUIC) included periods of rain that degraded one or both hotspot links.


---


### *Overall Interpretation*

In the lab, throughput differences of tens of megabits per second separated the best and worst schedulers, retransmissions were negligible and latency was stable. At sea, real mobile hotspot links reduced throughput by an order of magnitude, raised latency and introduced stall rates of 60–80% per measurement interval. Despite this, the relative ordering of the schedulers was partially preserved. For MPTCP, the heterogeneity-aware schedulers (EDF, LRTT, CWL) outperformed default and redundant, just as in the lab. EDF achieved the highest MPTCP throughput (5.08 Mbps) with the lowest retransmission rate (4 retransmits per minute on MSP–LAZ), while redundant performed worst because its packet duplication halved the already-limited bandwidth. For MP-QUIC, LRTT achieved the highest throughput (7.42 Mbps) by steering traffic toward the better-performing hotspot, BWA was the most stable, and RR degraded the most — suffering 95% ping loss on two segments when one path dropped out entirely.

The key takeaway is that emulated conditions overstate field throughput: real maritime links are bottlenecked by the cellular backhaul, not the scheduler, and conditions change on the scale of seconds. The schedulers that performed best at sea were those that react to path quality changes (EDF, LRTT, BWA) rather than those that assume stable conditions (default, RR), supporting the ITP1 design philosophy that heterogeneity-aware scheduling is more robust than uniform distribution.


---


## Limitations

Several limitations constrain the conclusions that can be drawn from this project.

The sea trial used personal phone hotspots as the two network paths. Mobile hotspot connectivity is subject to signal strength, carrier congestion, throttling policies and handover behaviour that vary by location, time of day and carrier. The test therefore measured the combined behaviour of the multipath scheduler and the phone's cellular modem, radio and tethering stack, making it impossible to attribute throughput differences purely to the scheduler. Dedicated maritime SIM cards or satellite terminals would have provided more stable and representative uplinks.

Weather affected one of the two test days. The MPQUIC tests on 9 November were partly conducted in rain, which degraded the cellular signal on both phones and introduced additional packet loss. Because the MPTCP tests on 5 November were conducted in clear weather, the two protocols were tested under unequal conditions, and their absolute throughput figures are not directly comparable.

Each scheduler was tested on two to three route segments of approximately 15–25 minutes each, with six to nine iperf3 runs per segment. This sample size is small relative to the variability of the links, and the stall percentages (60–83% for MPTCP) show that even within a single 180-second run the link could drop out for extended periods. A larger number of test runs across multiple days and routes would be needed to establish statistically significant performance rankings.

The iperf3 test generates a single long-lived TCP or QUIC flow, which is not representative of typical maritime application traffic (web browsing, telemetry, CCTV). The results characterise scheduler behaviour under sustained bulk transfer, not under the bursty, short-flow patterns that real applications produce.

The remote iperf3 server was hosted in Singapore, so the path latency was dominated by the cellular access link rather than by a long-haul satellite hop. A vessel further from shore, relying on VSAT for one or both paths, would see different scheduler behaviour because the path asymmetry would be much larger.

For the P4 theoretical study, the simulation used BMv2, a software model that executes P4 programs with the correct logic but not at hardware line rate. The throughput numbers from the simulation (Section 5.4) reflect Mininet's virtual link capacities, not the forwarding performance of a hardware P4 switch such as Intel Tofino.


## Future Work

Several directions follow from the limitations above.

Dedicated uplinks. Repeating the sea trial with dedicated mobile broadband dongles or maritime SIM cards on separate carriers would remove the phone's tethering stack from the measurement path and provide more stable, representative links. If a VSAT terminal is available, one path could be satellite and the other cellular, directly matching the heterogeneous maritime scenario the schedulers were designed for.

Extended and repeated trials. Running the test across multiple days, in different weather conditions and on different routes would increase the sample size and allow statistical confidence intervals to be placed on the throughput and latency differences between schedulers. Automating the test scripts to start and stop based on GPS waypoints rather than manual operator intervention would reduce human error and improve reproducibility.

Application-level traffic. Testing with realistic maritime workloads — HTTP browsing, video streaming, telemetry and SCADA — rather than a single iperf3 flow would reveal how the schedulers perform under short-flow and bursty conditions that matter more to end users.

Hardware P4 validation. Porting the P4 multipath scheduler to a hardware target such as an Intel Tofino switch and measuring its forwarding throughput and per-packet latency at line rate would validate the theoretical study against real hardware constraints.

MP-QUIC switch integration. Investigating how a P4 switch could schedule MP-QUIC traffic despite QUIC's encrypted headers, potentially using the QUIC Spin Bit for RTT estimation, would extend the theoretical study to cover the second protocol stack developed in this project.

Scheduler auto-selection. Developing a mechanism that selects the best scheduler dynamically based on observed path conditions, rather than requiring a manual choice before the test, would make the system more practical for deployment on a vessel where conditions change continuously.


## Lessons Learnt

The sea trial was the first time the team tested the multipath system outside the controlled lab, and the experience highlighted several lessons that are not apparent from emulation alone.

The gap between emulation and reality was larger than expected. In the lab, throughput was stable, retransmissions were negligible and schedulers performed within a few percent of each other across repeated runs. At sea, throughput varied by a factor of five within a single test session, stall rates exceeded 60% and some runs failed entirely because the hotspot link dropped out mid-transfer. The team learned that emulation is essential for isolating variables and comparing schedulers, but it cannot predict absolute field performance or reveal failure modes that depend on real radio conditions.

Test logistics matter as much as test design. The team underestimated the difficulty of running controlled tests on a moving ferry. Power management, keeping two phones tethered reliably, starting and stopping scripts at the right time and recording which scheduler was active on which segment all required coordination that would have benefited from a rehearsal run. On the rainy day, one phone's hotspot dropped repeatedly, and the team had to decide on the spot whether to restart the test or accept the partial data. A printed checklist and pre-assigned roles (one person per laptop, one person recording the schedule) would have reduced errors.

Redundancy in data collection is essential for field work. Several iperf3 runs failed with incomplete data because the connection dropped or the script was interrupted at an unexpected moment. The post-processing script was designed to handle partial runs and flag errors, which saved hours of manual inspection. In hindsight, running a background tcpdump or logging GPS coordinates alongside the iperf3 data would have provided additional context for understanding why certain runs failed.

Real-world multipath is bottlenecked by the weakest component, not the scheduler. In the lab, the scheduler is the variable under test and the links are deterministic. At sea, the phone's tethering stack, the carrier's congestion management, the radio conditions and even the ferry's steel hull all contributed to packet loss and throughput variation. The scheduler can only work with the paths it is given, and when both paths are poor, no scheduler can recover the throughput that the emulated testbed promised. This reinforces the importance of the heterogeneity-aware approach: schedulers that detect a degraded path and shift traffic away from it (EDF, LRTT, BWA) degrade gracefully, while those that assume both paths are usable (RR, redundant) collapse when one path fails.

Team coordination across objectives improved over the project. ITP2 involved six people working on four parallel objectives with shared infrastructure (the same kernel, the same server, the same test scripts). Early in the trimester, changes to the kernel for one objective broke the test setup for another. By the time of the sea trial, the team had established a branching and integration workflow that allowed parallel work without conflicts. The experience underscored that technical coordination is as important as the technical work itself.
