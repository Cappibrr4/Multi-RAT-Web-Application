#!/usr/bin/env bash
# =============================================================================
# Multi-RAT Dependency Checker
# Run on the TARGET MACHINE to see what's already installed.
# Usage: curl http://multirat-pi.local/check.sh | bash
# =============================================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $1"; }
miss() { echo -e "  ${RED}✗${NC}  $1"; }
info() { echo -e "  ${YELLOW}i${NC}  $1"; }

echo ""
echo "======================================="
echo "  Multi-RAT Dependency Check"
echo "======================================="
echo ""

# MPTCP kernel
echo "── MPTCP ──────────────────────────────"
if [[ -f /proc/sys/net/mptcp/enabled ]]; then
    ok "MPTCP kernel support present"
    ENABLED=$(cat /proc/sys/net/mptcp/enabled)
    [[ "$ENABLED" == "1" ]] && ok "MPTCP enabled" || info "MPTCP present but disabled (installer will enable)"
    SCHEDS=$(cat /proc/sys/net/mptcp/available_schedulers 2>/dev/null)
    info "Available schedulers: $SCHEDS"
else
    miss "MPTCP not supported — Ubuntu 22.04+ required"
fi
echo ""

# iperf3
echo "── iperf3 ─────────────────────────────"
if command -v iperf3 &>/dev/null; then
    ok "iperf3 $(iperf3 --version 2>&1 | head -1 | awk '{print $2}')"
else
    miss "iperf3 not installed"
fi

# mptcpize
if command -v mptcpize &>/dev/null; then
    ok "mptcpize installed"
else
    miss "mptcpize not installed"
fi
echo ""

# Go
echo "── Go / mp-quic ───────────────────────"
if command -v go &>/dev/null; then
    ok "Go $(go version | awk '{print $3}')"
else
    miss "Go not installed"
fi

if [[ -d /opt/mp-quic ]]; then
    ok "mp-quic at /opt/mp-quic"
else
    miss "mp-quic not found at /opt/mp-quic"
fi
echo ""

# Node / dashboard
echo "── Dashboard ──────────────────────────"
if command -v node &>/dev/null; then
    ok "Node.js $(node --version)"
else
    miss "Node.js not installed"
fi

if [[ -d /opt/multirat-dashboard ]]; then
    ok "Dashboard deployed at /opt/multirat-dashboard"
else
    miss "Dashboard not deployed"
fi

if systemctl is-enabled multirat-dashboard &>/dev/null; then
    ok "Dashboard service enabled (starts on boot)"
else
    info "Dashboard service not yet installed"
fi
echo ""

# Novel schedulers
echo "── Novel Schedulers ───────────────────"
for sched in hybrid cwl edf; do
    if lsmod 2>/dev/null | grep -q "mptcp_$sched"; then
        ok "mptcp_$sched loaded"
    elif [[ -f /opt/multirat-schedulers/${sched}.ko ]]; then
        info "mptcp_$sched found but not loaded (run: sudo insmod /opt/multirat-schedulers/${sched}.ko)"
    else
        miss "mptcp_$sched not found"
    fi
done
echo ""

echo "======================================="
echo "  Run the installer to fix missing items:"
echo "  curl http://multirat-pi.local/install.sh | sudo bash"
echo "======================================="
echo ""
