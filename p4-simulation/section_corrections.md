# Corrections for Jovan's Comments

---

## 1. Section 1.3 — Objective 4 (replace the whole paragraph)

OLD:
"4. Multipath Logic on Network Devices (Theoretical Study): Investigate in theory how multipath scheduling could be implemented on network devices, such as gateways or routers, rather than on each end host. This would allow every system on board to benefit from multipath transport without being individually configured. The study examines the possible architectures, their requirements and tradeoffs and the practical constraints of deploying them on a vessel. It remains a theoretical design and is not implemented within this project."

NEW:
"4. Multipath Logic on Network Devices (Theoretical Study): Investigate in theory how multipath scheduling could be implemented on network devices, such as gateways, transport converters or programmable Layer 3 switches, rather than on each end host. This would allow every system on board to benefit from multipath transport without being individually configured. The study examines the possible architectures, their requirements and tradeoffs and the practical constraints of deploying them on a vessel, and validates the proposed design through a proof-of-concept simulation using P4 on a software switch. It remains a theoretical study supported by simulation; it is not deployed on production hardware within this project."

---

## 2. Section 1.4 — Project Scope, second-last sentence of first paragraph (replace one sentence)

OLD:
"The deployment of multipath logic on network devices is covered as a theoretical study only."

NEW:
"The deployment of multipath logic on network devices is covered as a theoretical study supported by a proof-of-concept simulation on a software P4 switch."

---

## 3. Section 1.4 — Project Scope, second paragraph (replace one sentence)

OLD:
"Multipath logic on network devices is analysed but not implemented."

NEW:
"Multipath logic on network devices is analysed and validated through simulation but not deployed on production hardware."

---

## 4. Section 5.4 — Fix subsection numbering typos

5.41  -->  5.4.1  (missing dot in "Existing In-Network Multipath Approaches")

The second 5.4.3  -->  5.4.4  (the "Proposed Design" subsection is numbered the same as "Enabling Technology")

So the correct numbering should be:
- 5.4.1 Existing In-Network Multipath Approaches
- 5.4.2 Candidate Deployment Points on a Vessel
- 5.4.3 Enabling Technology: P4 Programmable Data Planes
- 5.4.4 Proposed Design: P4 Switch as the Multipath Scheduler
- 5.4.5 Feasibility Validation through Simulation
- 5.4.6 Limitations and Future Work
