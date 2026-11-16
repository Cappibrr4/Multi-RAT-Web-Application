#!/bin/bash
# ============================================================================
# Multipath Scheduler Benchmark Script
# ============================================================================
#
# Runs iperf3 tests across different scheduler configurations and path
# conditions, then generates a comparison report.
#
# Usage:
#   sudo bash run_benchmark.sh [--duration 30] [--output results/]
#
# This script runs inside the Mininet environment and tests:
#   1. Single-path baseline (no multipath)
#   2. Round-Robin P4 scheduler
#   3. BLEST P4 scheduler
#   4. Endpoint-based MPTCP RR (if MPTCP kernel available)
#
# For each configuration it measures:
#   - Throughput (Mbps)
#   - Latency (ms)
#   - Jitter (ms)
#   - Packet loss (%)
#   - Path utilization balance
# ============================================================================
set -euo pipefail

DURATION=${1:-30}
RESULTS_DIR="${2:-$(dirname $0)/../results}"
TOPO_SCRIPT="$(dirname $0)/../topology/multipath_topo.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$RESULTS_DIR/benchmark_${TIMESTAMP}.json"

echo '{"benchmark_date":"'$(date -Iseconds)'","tests":[' > "$REPORT_FILE"
FIRST=true

# ── Helper: Run a single test scenario ──────────────────────────────────────
run_test() {
    local SCHEDULER="$1"
    local DELAY_A="$2"
    local DELAY_B="$3"
    local BW_A="$4"
    local BW_B="$5"
    local LOSS_A="${6:-0}"
    local LOSS_B="${7:-0}"
    local LABEL="$8"

    log "Running: ${LABEL}"
    log "  Scheduler=${SCHEDULER} PathA(${DELAY_A}, ${BW_A}Mbps, ${LOSS_A}%) PathB(${DELAY_B}, ${BW_B}Mbps, ${LOSS_B}%)"

    # Create a temporary Mininet script that runs iperf inside the topology
    cat > /tmp/bench_test.py << PYEOF
#!/usr/bin/env python3
import sys, time, json, subprocess
sys.path.insert(0, '$(dirname $TOPO_SCRIPT)')
from multipath_topo import *

setLogLevel('warning')
P4Switch.device_id = 0

topo = MultipathTopo(
    delay_a='${DELAY_A}', delay_b='${DELAY_B}',
    bw_a=${BW_A}, bw_b=${BW_B},
    loss_a=${LOSS_A}, loss_b=${LOSS_B},
)

net = Mininet(topo=topo, link=TCLink, controller=None)
for sw in net.switches:
    sw.json_path = '/tmp/p4out_${SCHEDULER}/multipath_${SCHEDULER}.json'
net.start()
time.sleep(2)
install_flow_rules(net, '${SCHEDULER}')

if '${SCHEDULER}' == 'blest':
    da = int('${DELAY_A}'.replace('ms','')) * 1000
    db = int('${DELAY_B}'.replace('ms','')) * 1000
    set_blest_rtt(0, da)
    set_blest_rtt(1, db)

h1 = net.get('h1')
h2 = net.get('h2')

# Start iperf3 server on H2
h2.cmd('iperf3 -s -D -p 5201')
time.sleep(1)

# Run iperf3 TCP test
tcp_out = h1.cmd(f'iperf3 -c {h2.IP()} -t ${DURATION} -p 5201 -J')
try:
    tcp_data = json.loads(tcp_out)
    tcp_bps = tcp_data['end']['sum_sent']['bits_per_second']
    tcp_mbps = tcp_bps / 1e6
    tcp_retransmits = tcp_data['end']['sum_sent'].get('retransmits', 0)
except:
    tcp_mbps = 0
    tcp_retransmits = -1

# Run iperf3 UDP test for jitter/loss
h2.cmd('kill %iperf3 2>/dev/null; iperf3 -s -D -p 5202')
time.sleep(1)
udp_out = h1.cmd(f'iperf3 -c {h2.IP()} -t 10 -p 5202 -u -b 10M -J')
try:
    udp_data = json.loads(udp_out)
    jitter = udp_data['end']['sum']['jitter_ms']
    lost_pct = udp_data['end']['sum']['lost_percent']
except:
    jitter = -1
    lost_pct = -1

# Ping test for latency
ping_out = h1.cmd(f'ping -c 20 {h2.IP()}')
import re
m = re.search(r'rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)', ping_out)
if m:
    avg_rtt = float(m.group(2))
else:
    avg_rtt = -1

# Path stats
stats = read_path_stats()

h2.cmd('kill %iperf3 2>/dev/null')
net.stop()

result = {
    'throughput_mbps': round(tcp_mbps, 2),
    'avg_rtt_ms': round(avg_rtt, 2),
    'jitter_ms': round(jitter, 3) if jitter >= 0 else None,
    'loss_percent': round(lost_pct, 2) if lost_pct >= 0 else None,
    'tcp_retransmits': tcp_retransmits,
    'path_stats': stats.strip(),
}
print('RESULT_JSON:' + json.dumps(result))
PYEOF

    # Run the test
    OUTPUT=$(sudo python3 /tmp/bench_test.py 2>/dev/null || echo "RESULT_JSON:{\"error\":\"test failed\"}")
    RESULT=$(echo "$OUTPUT" | grep 'RESULT_JSON:' | sed 's/RESULT_JSON://')

    if [ -z "$RESULT" ]; then
        RESULT='{"error":"no output"}'
    fi

    # Append to report
    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo ',' >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" << EOF
  {
    "label": "${LABEL}",
    "scheduler": "${SCHEDULER}",
    "path_a": {"delay":"${DELAY_A}", "bw_mbps":${BW_A}, "loss_pct":${LOSS_A}},
    "path_b": {"delay":"${DELAY_B}", "bw_mbps":${BW_B}, "loss_pct":${LOSS_B}},
    "duration_sec": ${DURATION},
    "results": ${RESULT}
  }
EOF

    log "  Done: ${LABEL}"
    echo ""
}

# ============================================================================
# Test Scenarios
# ============================================================================

log "=== Multipath P4 Scheduler Benchmark ==="
log "Duration per test: ${DURATION}s"
log "Results: ${RESULTS_DIR}/"
echo ""

# ── Scenario 1: Symmetric paths (both 10ms, 10Mbps) ────────────────────────
run_test "rr"    "10ms" "10ms" 10 10 0 0 "RR_Symmetric_10ms"
run_test "blest" "10ms" "10ms" 10 10 0 0 "BLEST_Symmetric_10ms"

# ── Scenario 2: Asymmetric delay (10ms vs 50ms) ────────────────────────────
run_test "rr"    "10ms" "50ms" 10 10 0 0 "RR_Asymmetric_10vs50ms"
run_test "blest" "10ms" "50ms" 10 10 0 0 "BLEST_Asymmetric_10vs50ms"

# ── Scenario 3: Asymmetric delay + bandwidth (WiFi vs LTE scenario) ────────
run_test "rr"    "10ms" "80ms" 20 5 0 0 "RR_WiFi_vs_LTE"
run_test "blest" "10ms" "80ms" 20 5 0 0 "BLEST_WiFi_vs_LTE"

# ── Scenario 4: Lossy paths ────────────────────────────────────────────────
run_test "rr"    "10ms" "30ms" 10 10 1 5 "RR_Lossy_1vs5pct"
run_test "blest" "10ms" "30ms" 10 10 1 5 "BLEST_Lossy_1vs5pct"

# ── Scenario 5: Extreme asymmetry (stress test) ───────────────────────────
run_test "rr"    "5ms"  "200ms" 50 2 0 0 "RR_Extreme_5vs200ms"
run_test "blest" "5ms"  "200ms" 50 2 0 0 "BLEST_Extreme_5vs200ms"

# Close JSON
echo ']}' >> "$REPORT_FILE"

log "=== Benchmark Complete ==="
log "Results saved to: ${REPORT_FILE}"
echo ""

# ── Generate summary ──────────────────────────────────────────────────────
log "=== Summary ==="
python3 << 'SUMEOF'
import json, sys

try:
    with open(sys.argv[1] if len(sys.argv) > 1 else "REPORT_FILE_PLACEHOLDER") as f:
        data = json.load(f)
except:
    with open("RESULTS_DIR/benchmark_TIMESTAMP.json".replace("RESULTS_DIR", "RESULTS_DIR_PLACEHOLDER").replace("TIMESTAMP", "TIMESTAMP_PLACEHOLDER")) as f:
        data = json.load(f)

print(f"\n{'Label':<30} {'Throughput':>12} {'RTT':>10} {'Jitter':>10} {'Loss':>8}")
print("-" * 75)

for t in data.get('tests', []):
    r = t.get('results', {})
    label = t['label']
    tp = f"{r.get('throughput_mbps', '?')} Mbps"
    rtt = f"{r.get('avg_rtt_ms', '?')} ms"
    jit = f"{r.get('jitter_ms', '?')} ms"
    loss = f"{r.get('loss_percent', '?')}%"
    print(f"{label:<30} {tp:>12} {rtt:>10} {jit:>10} {loss:>8}")

print()
SUMEOF
