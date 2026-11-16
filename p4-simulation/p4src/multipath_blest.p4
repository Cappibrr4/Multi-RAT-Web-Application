/* ============================================================================
 * multipath_blest.p4 — BLEST-inspired Multipath Scheduler for BMv2
 * ============================================================================
 *
 * P4_16 program implementing a BLEST-like (Blocking ESTimation) scheduler
 * on the switch data plane. This is the P4 equivalent of sched_blest.c.
 *
 * BLEST avoids Head-of-Line (HoL) blocking by estimating whether sending
 * on the slow path will cause the receiver to stall waiting for reordering.
 *
 * Key insight for P4 implementation:
 *   The switch can't access TCP state (cwnd, srtt) directly. Instead, we:
 *   1. Measure per-path RTT using probe packets (or controller updates)
 *   2. Track per-path utilization via packet counters
 *   3. Use a simplified HoL prediction based on path delay difference
 *
 * This demonstrates that BLEST's *principle* (avoid slow paths when delay
 * difference is too high) can be enforced at the switch level.
 *
 * Reference: Ferlin et al., "BLEST: Blocking Estimation-based MPTCP
 *            Scheduler" (IFIP Networking 2016)
 * ============================================================================
 */

#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x0800;

#define NUM_PATHS      2
#define RTT_THRESHOLD  50000   /* 50ms in microseconds — if path delay
                                  difference exceeds this, avoid the slow
                                  path to prevent HoL blocking */
#define LAMBDA_INIT    1000    /* Lambda scaling factor × 1000 (= 1.0) */
#define LAMBDA_STEP    5       /* Adaptation step (0.005) */
#define LAMBDA_MAX     3000    /* Max lambda (= 3.0) */

/* ── Headers ────────────────────────────────────────────────────────────── */
header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<4>  res;
    bit<8>  flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length_;
    bit<16> checksum;
}

struct metadata_t {
    bit<9>  selected_port;
    bit<1>  is_multipath;
    bit<1>  hol_predicted;
    bit<32> path_a_rtt;
    bit<32> path_b_rtt;
    bit<32> path_a_util;
    bit<32> path_b_util;
}

struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    tcp_t      tcp;
    udp_t      udp;
}

/* ── Parser ─────────────────────────────────────────────────────────────── */
parser MyParser(packet_in packet,
                out headers_t hdr,
                inout metadata_t meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            6:       parse_tcp;
            17:      parse_udp;
            default: accept;
        }
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition accept;
    }
}

/* ── Checksum Verification ──────────────────────────────────────────────── */
control MyVerifyChecksum(inout headers_t hdr, inout metadata_t meta) {
    apply { }
}

/* ── Ingress Processing ─────────────────────────────────────────────────── */
control MyIngress(inout headers_t hdr,
                  inout metadata_t meta,
                  inout standard_metadata_t standard_metadata) {

    /* Counters */
    counter(NUM_PATHS, CounterType.packets_and_bytes) path_counter;

    /* Per-path RTT estimates (populated by controller via register writes).
     * In a real deployment, the controller runs periodic probes or reads
     * INT (In-band Network Telemetry) metadata to update these. */
    register<bit<32>>(NUM_PATHS) path_rtt;

    /* Per-path packet counts (utilization proxy) */
    register<bit<32>>(NUM_PATHS) path_pkt_count;

    /* Lambda adaptation register */
    register<bit<32>>(1) lambda_reg;

    /* Fallback RR index (when BLEST can't decide) */
    register<bit<32>>(1) rr_fallback;

    /* ── Actions ──────────────────────────────────────────────────────── */
    action drop() {
        mark_to_drop(standard_metadata);
    }

    action forward(bit<9> port, bit<48> dstMac) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.dstAddr = dstMac;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    /*
     * BLEST path selection — simplified for P4 data plane.
     *
     * Original BLEST (kernel):
     *   X = cwnd_fast * (rtt_slow - rtt_fast) / rtt_fast * lambda
     *   if in_flight_slow >= X → skip slow path (HoL predicted)
     *
     * P4 BLEST (switch):
     *   We don't have cwnd or in_flight. Instead:
     *   1. Read per-path RTT from registers (controller-populated)
     *   2. If RTT difference > threshold → avoid slow path
     *   3. If both paths similar RTT → round-robin
     *   4. Lambda adapts based on path utilization imbalance
     *
     * This captures BLEST's core principle: avoid the slow path when
     * the delay asymmetry would cause reordering at the receiver.
     */
    action multipath_blest_select() {
        bit<32> rtt_a;
        bit<32> rtt_b;
        bit<32> util_a;
        bit<32> util_b;
        bit<32> lam;

        /* Read path state */
        path_rtt.read(rtt_a, 0);      /* Path A (port 2) RTT in us */
        path_rtt.read(rtt_b, 1);      /* Path B (port 3) RTT in us */
        path_pkt_count.read(util_a, 0);
        path_pkt_count.read(util_b, 1);
        lambda_reg.read(lam, 0);

        /* Initialize lambda if zero */
        if (lam == 0) {
            lam = LAMBDA_INIT;
            lambda_reg.write(0, lam);
        }

        /* Store in metadata for logging */
        meta.path_a_rtt = rtt_a;
        meta.path_b_rtt = rtt_b;
        meta.path_a_util = util_a;
        meta.path_b_util = util_b;

        /* Default: use faster path */
        meta.is_multipath = 1;

        if (rtt_a == 0 && rtt_b == 0) {
            /* No RTT data yet — fall back to round-robin */
            bit<32> idx;
            rr_fallback.read(idx, 0);
            if (idx == 0) {
                meta.selected_port = 2;
            } else {
                meta.selected_port = 3;
            }
            idx = (idx + 1) % NUM_PATHS;
            rr_fallback.write(0, idx);

        } else if (rtt_a <= rtt_b) {
            /* Path A is faster (or equal) */
            bit<32> diff = rtt_b - rtt_a;

            /* Scale diff by lambda: effective_diff = diff * lam >> 10
             * (>> 10 ≈ / 1024 ≈ / 1000; P4 has no division) */
            bit<32> scaled_diff = (diff * lam) >> 10;

            if (scaled_diff > RTT_THRESHOLD) {
                /* HoL predicted on Path B — use only Path A */
                meta.selected_port = 2;
                meta.hol_predicted = 1;
            } else {
                /* Both paths OK — round-robin */
                bit<32> idx;
                rr_fallback.read(idx, 0);
                if (idx == 0) {
                    meta.selected_port = 2;
                } else {
                    meta.selected_port = 3;
                }
                idx = (idx + 1) % NUM_PATHS;
                rr_fallback.write(0, idx);
            }

        } else {
            /* Path B is faster */
            bit<32> diff = rtt_a - rtt_b;
            bit<32> scaled_diff = (diff * lam) >> 10;

            if (scaled_diff > RTT_THRESHOLD) {
                /* HoL predicted on Path A — use only Path B */
                meta.selected_port = 3;
                meta.hol_predicted = 1;
            } else {
                bit<32> idx;
                rr_fallback.read(idx, 0);
                if (idx == 0) {
                    meta.selected_port = 2;
                } else {
                    meta.selected_port = 3;
                }
                idx = (idx + 1) % NUM_PATHS;
                rr_fallback.write(0, idx);
            }
        }

        /* Update per-path counters */
        bit<32> path_idx = (bit<32>)meta.selected_port - 2;
        bit<32> count;
        path_pkt_count.read(count, path_idx);
        path_pkt_count.write(path_idx, count + 1);
        path_counter.count(path_idx);

        /* Lambda adaptation: if utilization is very imbalanced,
         * increase lambda (more aggressive HoL avoidance).
         * P4 has no division — use multiply-compare instead:
         *   ratio > 3  becomes  bigger > 3 * smaller
         *   ratio < 2  becomes  bigger < 2 * smaller  */
        if (util_a > 0 && util_b > 0) {
            bit<32> bigger;
            bit<32> smaller;
            if (util_a > util_b) {
                bigger = util_a;
                smaller = util_b;
            } else {
                bigger = util_b;
                smaller = util_a;
            }
            if (bigger > (smaller << 1) + smaller) {
                /* bigger > 3× smaller — very imbalanced */
                if (lam < LAMBDA_MAX) {
                    lam = lam + LAMBDA_STEP;
                    lambda_reg.write(0, lam);
                }
            } else if (bigger < (smaller << 1) && lam > LAMBDA_STEP) {
                /* bigger < 2× smaller — balanced */
                lam = lam - LAMBDA_STEP;
                lambda_reg.write(0, lam);
            }
        }
    }

    /* ── Tables ───────────────────────────────────────────────────────── */
    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }

    table multipath_route {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            multipath_blest_select;
            NoAction;
        }
        size = 256;
        default_action = NoAction();
    }

    apply {
        if (!hdr.ipv4.isValid()) {
            drop();
            return;
        }

        multipath_route.apply();

        if (meta.is_multipath == 1) {
            standard_metadata.egress_spec = meta.selected_port;
            hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        } else {
            ipv4_lpm.apply();
        }
    }
}

/* ── Egress Processing ──────────────────────────────────────────────────── */
control MyEgress(inout headers_t hdr,
                 inout metadata_t meta,
                 inout standard_metadata_t standard_metadata) {

    action set_src_mac(bit<48> srcMac) {
        hdr.ethernet.srcAddr = srcMac;
    }

    table egress_mac {
        key = {
            standard_metadata.egress_port: exact;
        }
        actions = {
            set_src_mac;
            NoAction;
        }
        size = 16;
        default_action = NoAction();
    }

    apply {
        egress_mac.apply();
    }
}

/* ── Checksum Computation ───────────────────────────────────────────────── */
control MyComputeChecksum(inout headers_t hdr, inout metadata_t meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version,
              hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/* ── Deparser ───────────────────────────────────────────────────────────── */
control MyDeparser(packet_out packet, in headers_t hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
        packet.emit(hdr.udp);
    }
}

/* ── Switch Instance ────────────────────────────────────────────────────── */
V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
