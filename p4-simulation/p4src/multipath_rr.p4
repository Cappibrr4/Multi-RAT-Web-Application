/* ============================================================================
 * multipath_rr.p4 — Round-Robin Multipath Scheduler for BMv2
 * ============================================================================
 *
 * P4_16 program that implements a round-robin packet scheduler across
 * multiple output ports (paths). This is the P4 data-plane equivalent
 * of the kernel-space MPTCP Round-Robin scheduler (sched_rr.c).
 *
 * Architecture: v1model (BMv2 simple_switch)
 *
 * Key difference from endpoint scheduling:
 *   - Endpoint RR: OS kernel picks which subflow/interface to send on
 *   - Switch RR:   The switch itself distributes packets across paths
 *                  → Zero endpoint overhead, transparent to applications
 *
 * Reference: Motohashi et al., "Implementation of P4-Based Schedulers
 *            for Multipath Communications" (IEEE Access, 2022)
 * ============================================================================
 */

#include <core.p4>
#include <v1model.p4>

/* ── Constants ──────────────────────────────────────────────────────────── */
const bit<16> TYPE_IPV4 = 0x0800;
const bit<16> TYPE_ARP  = 0x0806;

/* Number of egress ports (paths) available — matches our topology */
#define NUM_PATHS 2

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
    bit<32> flow_hash;
    bit<9>  selected_port;
    bit<1>  is_multipath;
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

    /* ── Counters for monitoring ───────────────────────────────────────── */
    counter(NUM_PATHS, CounterType.packets_and_bytes) path_counter;

    /* ── Register: round-robin index (persistent across packets) ──────── */
    register<bit<32>>(1) rr_index;

    /* ── Register: per-path packet counts (for dashboard/stats) ───────── */
    register<bit<32>>(NUM_PATHS) path_pkt_count;

    /* ── Actions ──────────────────────────────────────────────────────── */
    action drop() {
        mark_to_drop(standard_metadata);
    }

    action forward(bit<9> port, bit<48> dstMac) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.dstAddr = dstMac;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    /* Round-Robin path selection
     *
     * This is the P4 equivalent of sched_rr.c's logic:
     *   - Kernel RR: iterates subflows, picks index % count
     *   - P4 RR:    reads register index, picks port = (index % NUM_PATHS)
     *
     * The key advantage: this runs at switch line rate, not in the OS.
     */
    action multipath_rr_select() {
        bit<32> idx;
        rr_index.read(idx, 0);

        /* Select output port based on RR index */
        /* Ports 2 and 3 are the two paths to the destination */
        if (idx == 0) {
            meta.selected_port = 2;  /* Path A */
        } else {
            meta.selected_port = 3;  /* Path B */
        }

        /* Advance RR counter */
        idx = (idx + 1) % NUM_PATHS;
        rr_index.write(0, idx);

        /* Update per-path stats */
        bit<32> count;
        bit<32> path_idx = (bit<32>)meta.selected_port - 2;
        path_pkt_count.read(count, path_idx);
        path_pkt_count.write(path_idx, count + 1);

        /* Increment hardware counter */
        path_counter.count(path_idx);

        meta.is_multipath = 1;
    }

    /* ── Tables ───────────────────────────────────────────────────────── */

    /* Standard L3 forwarding table */
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

    /* Multipath routing table — matches destination prefixes that
     * should be load-balanced across multiple paths */
    table multipath_route {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            multipath_rr_select;
            NoAction;
        }
        size = 256;
        default_action = NoAction();
    }

    apply {
        if (!hdr.ipv4.isValid()) {
            /* Non-IPv4: flood or drop */
            drop();
            return;
        }

        /* Check if this destination should be multipath-scheduled */
        multipath_route.apply();

        if (meta.is_multipath == 1) {
            /* Multipath: use the RR-selected port */
            standard_metadata.egress_spec = meta.selected_port;
            hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        } else {
            /* Single path: standard L3 forwarding */
            ipv4_lpm.apply();
        }
    }
}

/* ── Egress Processing ──────────────────────────────────────────────────── */
control MyEgress(inout headers_t hdr,
                 inout metadata_t meta,
                 inout standard_metadata_t standard_metadata) {

    /* Rewrite source MAC based on egress port */
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
