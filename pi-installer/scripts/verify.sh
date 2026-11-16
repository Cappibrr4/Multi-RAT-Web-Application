#!/usr/bin/env bash
# =============================================================================
# Multi-RAT Installation Verification
# Run this after installation + reboot to confirm everything is working.
#
# Usage:
#   bash verify.sh
# =============================================================================

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  \e[32m[OK]\e[0m   $1"; ((PASS++)); }
fail() { echo -e "  \e[31m[FAIL]\e[0m $1"; ((FAIL++)); }
warn() { echo -e "  \e[33m[WARN]\e[0m $1"; ((WARN++)); }

echo ""
echo "========================================"
echo " Multi-RAT Installation Verification"
echo "========================================"
echo ""

# ── Kernel ───────────────────────────────────────────────────────────────────
echo "Kernel:"
KVER=$(uname -r)
if echo "$KVER" | grep -qE "rc|mptcp"; then
    pass "Running MPTCP kernel: $KVER"
else
    fail "Not running MPTCP kernel (current: $KVER) -- reboot required?"
fi

if sysctl -n net.mptcp.enabled 2>/dev/null | grep -q "1"; then
    pass "MPTCP enabled (net.mptcp.enabled = 1)"
else
    fail "MPTCP not enabled"
fi
echo ""

# ── Novel MPTCP Schedulers ───────────────────────────────────────────────────
echo "MPTCP Schedulers:"
SCHED_DIR="/opt/mptcp_net-next/net/mptcp"
EXPECTED_SCHEDS="hybridsched sched_novelcwl sched_noveledf sched_lrtt sched_blest sched_ecf sched_rr sched_redundant"
for s in $EXPECTED_SCHEDS; do
    if [[ -f "$SCHED_DIR/${s}.c" ]]; then
        pass "$s.c present in kernel tree"
    else
        fail "$s.c missing from kernel tree"
    fi
done
echo ""

# ── Go ───────────────────────────────────────────────────────────────────────
echo "Go:"
if command -v go &>/dev/null; then
    pass "Go installed: $(go version 2>/dev/null | awk '{print $3}')"
elif [[ -x /usr/local/go/bin/go ]]; then
    pass "Go installed: $(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')"
else
    fail "Go not installed"
fi
echo ""

# ── mp-quic ──────────────────────────────────────────────────────────────────
echo "mp-quic:"
if [[ -d "/opt/mp-quic" ]] && ls /opt/mp-quic/*.go &>/dev/null 2>&1; then
    pass "mp-quic source at /opt/mp-quic"
else
    fail "mp-quic not found at /opt/mp-quic"
fi

if [[ -f "/opt/mp-quic/scheduler.go" ]]; then
    pass "MPQUIC scheduler.go present"
else
    warn "scheduler.go not found"
fi
echo ""

# ── Dashboard ────────────────────────────────────────────────────────────────
echo "Dashboard:"
if systemctl is-active --quiet multirat-dashboard 2>/dev/null; then
    pass "multirat-dashboard service is running"
elif systemctl is-enabled --quiet multirat-dashboard 2>/dev/null; then
    warn "multirat-dashboard enabled but not running -- try: sudo systemctl start multirat-dashboard"
else
    fail "multirat-dashboard service not installed"
fi

if curl -sf --connect-timeout 3 http://localhost:3000 &>/dev/null; then
    pass "Dashboard responding at http://localhost:3000"
else
    warn "Dashboard not responding at http://localhost:3000"
fi

if curl -sf --connect-timeout 3 http://localhost:5000 &>/dev/null; then
    pass "Backend API responding at http://localhost:5000"
else
    warn "Backend API not responding at http://localhost:5000"
fi
echo ""

# ── Networking Tools ─────────────────────────────────────────────────────────
echo "Networking Tools:"
TOOLS="iperf3 mptcpize bmon htop tcpdump nload ethtool traceroute"
for tool in $TOOLS; do
    if command -v "$tool" &>/dev/null; then
        pass "$tool"
    else
        fail "$tool not found"
    fi
done
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "========================================"
TOTAL=$((PASS + FAIL + WARN))
echo -e "  \e[32m$PASS passed\e[0m  |  \e[31m$FAIL failed\e[0m  |  \e[33m$WARN warnings\e[0m  |  $TOTAL total"

if [[ $FAIL -eq 0 ]]; then
    echo ""
    echo -e "  \e[32mAll checks passed! Installation is complete.\e[0m"
    echo "  Open http://localhost:3000 to use the dashboard."
else
    echo ""
    echo -e "  \e[31mSome checks failed. Re-run the installer or fix manually.\e[0m"
fi
echo "========================================"
echo ""
