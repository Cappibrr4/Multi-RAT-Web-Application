import React, { useState } from 'react';
import './HomePage.css';

// ---------------------------------------------------------------------------
// Home page: Technical Architecture only.
// Describes every scheduler in the project, grouped by protocol.
// ---------------------------------------------------------------------------

const SCHEDULERS = {
    MPTCP: [
        {
            name: 'Default',
            tag: 'minimum linger time',
            novel: false,
            desc: 'The Linux upstream scheduler. It picks the subflow whose send queue should empty soonest, a value called the linger time, which tends to favour paths with low RTT and high rate. Simple and works well when paths are alike.',
            formula: 'linger = (sk_wmem_queued << 32) / avg_pacing_rate',
        },
        {
            name: 'Round Robin',
            tag: 'rrpacket',
            novel: false,
            desc: 'Spreads segments evenly across all active subflows without looking at path quality. A fair baseline, but it does not adapt to RTT or loss.',
            formula: 'pick next active subflow in rotation',
        },
        {
            name: 'LRTT',
            tag: 'lowest RTT first',
            novel: false,
            desc: 'Always picks the subflow with the lowest smoothed RTT, and skips a path that already holds more than about twice its bandwidth delay product of unsent data. Latency stays low, but higher RTT paths can be underused.',
            formula: 'pick argmin(srtt_us >> 3)',
        },
        {
            name: 'Redundant',
            tag: 'all paths',
            novel: false,
            desc: 'Sends every segment on all subflows at once. Latency is as low as possible and the connection tolerates loss, but the bandwidth is spent more than once.',
            formula: 'schedule every active subflow each round',
        },
        {
            name: 'BLEST',
            tag: 'blocking estimation',
            novel: false,
            desc: 'Predicts head of line blocking on uneven paths and holds back a slower path when using it would stall the connection. A correction factor adapts on retransmission signals.',
            formula: 'X = cwnd_fast x (rtt_slow - rtt_fast) / rtt_fast x (lambda / 1000)',
        },
        {
            name: 'ECF',
            tag: 'earliest completion first',
            novel: false,
            desc: 'Estimates, from RTT and the congestion window, which subflow will deliver the next segment soonest, and schedules that one. It holds back a subflow that would only finish later.',
            formula: 'completion = ((in_flight + 1) x srtt) / (cwnd - in_flight)',
        },
        {
            name: 'Hybrid',
            tag: 'RTT linger, novel',
            novel: true,
            desc: 'Our first novel design. It multiplies the default linger term by an explicit RTT factor so latency counts for more. Because the pacing rate already contains RTT, this squares the RTT effect, which motivated the CWL design below.',
            formula: 'score = (wmem x RTT) / avg_pacing_rate',
        },
        {
            name: 'CWL',
            tag: 'congestion weighted linger, novel',
            novel: true,
            desc: 'Our second novel MPTCP scheduler. It keeps the default linger term and multiplies it by a weight that reflects how full the congestion window is, nudging new data toward less busy paths. RTT stays implicit in the pacing rate, so there is no RTT squaring. When a path is idle the weight is one and the score equals the default linger time, so CWL2 cannot regress below the baseline in the idle-window case.',
            formula: 'score = ((wmem << 32) / pace) × (SCALE + fill × ALPHA) / SCALE',
        },
        {
            name: 'EDF',
            tag: 'earliest delivery first, novel',
            novel: true,
            desc: 'Our third novel MPTCP scheduler. For every eligible subflow it estimates when the next segment would be delivered — roughly half an RTT away if the window has room, or about one and a half RTTs away if it is full — and picks the subflow with the earliest delivery. Revision 2 separates the head-of-line blocking guard from path selection using MinRTT as the reference, so the scheduler correctly returns to a path after a transient RTT spike instead of staying stuck on a single path.',
            formula: 'delivery ≈ srtt / 2 (window free)  or  srtt × 1.5 (window full)',
        },
    ],
    MPQUIC: [
        {
            name: 'Round Robin',
            tag: 'lowest quota',
            novel: false,
            desc: 'Picks the eligible path with the lowest quota, so the paths take turns evenly. Simple and fair, but it ignores RTT, loss, and bandwidth.',
            formula: 'pick argmin(quota)',
        },
        {
            name: 'Low Latency',
            tag: 'lowest RTT',
            novel: false,
            desc: 'Picks the eligible path with the lowest smoothed RTT, which keeps traffic on the fastest path. A single odd RTT reading can make the choice jump between paths.',
            formula: 'pick argmin(SmoothedRTT)',
        },
        {
            name: 'BWLS',
            tag: 'bandwidth latency score, novel',
            novel: true,
            desc: 'Our first novel MPQUIC scheduler. It ranks paths with a score that combines damped latency and a capacity signal to reduce the path-flapping that Low Latency suffers. Each path maintains a slow running average of its RTT (baseline = 0.9 × baseline + 0.1 × RTT) and sudden spikes are capped at twice that baseline before scoring, so a brief latency jump at most halves the score instead of removing the path entirely. Paths that are not congested receive a ×2 score boost. The direct answer to LRTT-style flapping — but the binary capacity gate (SendingAllowed) causes oscillation when both paths are busy, which motivated the BWA design.',
            formula: 'effRTT = min(RTT, 2 × baseline)   →   score = 1 / (effRTT + 1ms)   [×2 if SendingAllowed]',
        },
        {
            name: 'BWA',
            tag: 'bandwidth-weighted arrival, novel',
            novel: true,
            desc: 'Our novel MPQUIC scheduler — the counterpart of EDF on the MPQUIC side. For each eligible path it computes a genuine delivery-rate estimate (rate = cwnd / srtt) and uses it to predict when a new packet would actually arrive: the time to drain the in-flight queue at that rate, plus half an RTT of propagation. The path with the smallest arrival time wins. A 12.5 % stickiness margin (×0.875 on the incumbent\'s arrival) damps path-flapping by requiring a challenger to be clearly faster before a switch happens. A head-of-line guard skips any path whose MinRTT exceeds three times the fastest path\'s MinRTT, with a guard-free fallback if every path is bloated. This bandwidth signal — rather than the binary congestion gate used by BWLS — is what eliminates packet loss under spiking conditions (Setup B: 25 retransmissions vs BWLS\'s 102, zero packet loss vs 732).',
            formula: 'rate = cwnd / srtt   →   arrival = inflight / rate + srtt / 2',
        },
    ],
};

const HomePage = () => {
    const [tab, setTab] = useState('MPTCP');
    const list = SCHEDULERS[tab];

    return (
        <div className="home-page">
            {/* Hero */}
            <div className="home-hero">
                <h1 className="home-hero-title">Technical Architecture</h1>
                <p className="home-hero-subtitle">
                    Multipath scheduler design for MPTCP and MPQUIC
                </p>
            </div>

            <div className="home-content">
                <p className="home-intro">
                    This project designs and evaluates packet schedulers for two multipath transport protocols.
                    A scheduler decides, for every unit of data, which network path should carry it. Below are the
                    schedulers built for each protocol, including the three novel MPTCP schedulers (Hybrid, CWL2, EDF2)
                    and two novel MPQUIC schedulers (BWLS, BWA) designed for this project.
                </p>

                {/* Protocol tabs */}
                <div className="home-tabs">
                    {Object.keys(SCHEDULERS).map(p => (
                        <button
                            key={p}
                            onClick={() => setTab(p)}
                            className={`home-tab ${tab === p ? 'is-active' : ''}`}
                        >
                            {p}
                        </button>
                    ))}
                </div>

                {/* Scheduler cards */}
                <div className="home-grid">
                    {list.map(s => (
                        <div key={s.name} className={`home-card ${s.novel ? 'is-novel' : ''}`}>
                            <div className="home-card-head">
                                <h3 className="home-card-name">{s.name}</h3>
                                {s.novel && <span className="home-badge">NOVEL</span>}
                            </div>
                            <div className="home-card-tag">{s.tag}</div>
                            <p className="home-card-desc">{s.desc}</p>
                            <div className="home-card-formula">{s.formula}</div>
                        </div>
                    ))}
                </div>
            </div>
        </div>
    );
};

export default HomePage;