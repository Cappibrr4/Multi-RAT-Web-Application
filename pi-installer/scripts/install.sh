#!/usr/bin/env bash
# =============================================================================
# Multi-RAT Full Installer  (v2 — fully plug-and-play)
# Runs on the TARGET MACHINE (the ship's computer / clean Ubuntu machine).
#
# Usage (on target machine — just TWO commands):
#   curl http://<PI_IP>/install.sh -o install.sh
#   sudo bash install.sh
#
# The script auto-detects the Pi's IP address. No arguments needed.
#
# What this installs:
#   1. Build dependencies (iperf3, mptcpize, bmon, htop, etc.)
#   2. Custom MPTCP kernel (mptcp_net-next) with all novel schedulers
#   3. Go 1.20.14 + mp-quic with MPQUIC schedulers (BWA/BWLS)
#   4. Multi-RAT Dashboard (React + Python backend)
# =============================================================================

# ── Self-fix: strip Windows line endings if present ──────────────────────────
if [[ "$(head -c2 "$0" | od -An -tx1 | tr -d ' ')" == *"0d"* ]] || grep -qP '\r$' "$0" 2>/dev/null; then
    sed -i 's/\r$//' "$0"
    exec bash "$0" "$@"
fi

set -euo pipefail

# ── Must run as root ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Try:"
    echo "  sudo bash install.sh"
    exit 1
fi

# ── Pi host: pass as argument, or auto-detect ────────────────────────────────
detect_pi() {
    # 1. Try mDNS hostname
    for candidate in "http://multirat-pi.local" "http://192.168.42.1"; do
        if curl -sf --connect-timeout 2 "$candidate/api/status" &>/dev/null; then
            echo "$candidate"
            return
        fi
    done

    # 2. Try the default gateway (Pi runs DHCP, so it IS the gateway)
    local gw
    gw=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -1)
    if [[ -n "$gw" ]] && curl -sf --connect-timeout 2 "http://${gw}/api/status" &>/dev/null; then
        echo "http://${gw}"
        return
    fi

    # 3. Scan all directly-connected subnets for the Pi web server
    local iface_ip subnet
    for iface_ip in $(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}'); do
        subnet="${iface_ip%.*}"
        for last in 1 100 200 254; do
            if curl -sf --connect-timeout 1 "http://${subnet}.${last}/api/status" &>/dev/null; then
                echo "http://${subnet}.${last}"
                return
            fi
        done
    done

    return 1
}

if [[ -n "${1:-}" ]]; then
    PI_HOST="$1"
else
    echo "Auto-detecting Pi..."
    PI_HOST=$(detect_pi) || {
        echo "Could not auto-detect Pi. Pass the Pi's IP as argument:"
        echo "  sudo bash install.sh http://<PI_IP>"
        exit 1
    }
fi
echo "Using Pi at: $PI_HOST"

KERNEL_SRC="/opt/mptcp_net-next"
MPQUIC_DIR="/opt/mp-quic"
DASHBOARD_DIR="/opt/multirat-dashboard"
GO_VERSION="1.20.14"

# Detect architecture
ARCH=$(uname -m)
GO_ARCH="linux-amd64"
[[ "$ARCH" == "aarch64" ]] && GO_ARCH="linux-arm64"

# ── Simple log helpers ────────────────────────────────────────────────────────
ok()      { echo -e "\e[32m[OK]\e[0m    [$1] $2"; }
info()    { echo -e "\e[33m[....]\e[0m  [$1] $2"; }
err()     { echo -e "\e[31m[FAIL]\e[0m  [$1] $2" >&2; exit 1; }

# =============================================================================
# STEP 0 — Fix system clock (prevents apt "Release not valid yet" errors)
# =============================================================================
info "CLOCK" "Syncing system clock..."
if command -v timedatectl &>/dev/null; then
    timedatectl set-ntp true 2>/dev/null || true
elif command -v ntpdate &>/dev/null; then
    ntpdate -s ntp.ubuntu.com 2>/dev/null || true
else
    # Fallback: get time from Pi's HTTP Date header
    PI_DATE=$(curl -sI "$PI_HOST/" 2>/dev/null | grep -i '^date:' | cut -d' ' -f2-)
    if [[ -n "$PI_DATE" ]]; then
        date -s "$PI_DATE" &>/dev/null || true
    fi
fi
ok "CLOCK" "Clock synced"

# =============================================================================
# STEP 1 — System update + build dependencies
# =============================================================================
info "APT" "Updating system and installing build dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq -o Acquire::Check-Valid-Until=false 2>/dev/null || apt-get update -qq || true
apt-get install -y -qq \
    build-essential libncurses-dev gawk flex bison openssl libssl-dev \
    dkms libelf-dev libudev-dev libpci-dev autoconf llvm rsync dwarves \
    libdw-dev libdwarf-dev git bc kmod cpio zstd curl iperf3 mptcpize \
    bmon htop net-tools ethtool traceroute tcpdump nload iproute2 \
    || err "APT" "Dependency installation failed"
ok "APT" "Build dependencies installed"

# =============================================================================
# STEP 2 — Clone mptcp_net-next kernel source
# =============================================================================
info "KERNEL-SRC" "Cloning mptcp_net-next kernel source (this may take a few minutes)..."
if [[ -d "$KERNEL_SRC/.git" ]]; then
    ok "KERNEL-SRC" "Kernel source already present -- skipping clone"
else
    git clone --depth 1 https://github.com/multipath-tcp/mptcp_net-next.git "$KERNEL_SRC" \
        || err "KERNEL-SRC" "Failed to clone kernel source -- internet required for first install"
    ok "KERNEL-SRC" "Kernel source cloned"
fi

# =============================================================================
# STEP 3 — Add all schedulers to the kernel source
# =============================================================================
info "SCHED-INJECT" "Injecting schedulers into kernel source..."

SCHED_PATH="$KERNEL_SRC/net/mptcp"

# Download all scheduler .c files from Pi
SCHED_FILES="hybridsched.c sched_novelcwl.c sched_noveledf.c sched.c sched_lrtt.c sched_blest.c sched_ecf.c sched_rr.c sched_redundant.c"
for fname in $SCHED_FILES; do
    curl -sf "$PI_HOST/payloads/schedulers/$fname" -o "$SCHED_PATH/$fname" \
        || echo "  Warning: could not download $fname from Pi"
done
ok "SCHED-INJECT" "Scheduler source files copied to kernel tree"

# Patch Makefile -- add each novel scheduler object
MAKEFILE="$SCHED_PATH/Makefile"
declare -A SCHED_OBJS=(
    ["hybridsched.c"]="CONFIG_MPTCP_HYBRID|mptcp-hybrid|Hybrid RTT-Linger scheduler"
    ["sched_novelcwl.c"]="CONFIG_MPTCP_NOVELCWL|mptcp-novelcwl|Congestion-Weighted Linger scheduler"
    ["sched_noveledf.c"]="CONFIG_MPTCP_NOVELEDF|mptcp-noveledf|Earliest-Delivery-First scheduler"
    ["sched_lrtt.c"]="CONFIG_MPTCP_LRTT|mptcp-lrtt|Lowest RTT First scheduler"
    ["sched_blest.c"]="CONFIG_MPTCP_BLEST|mptcp-blest|BLEST scheduler"
    ["sched_ecf.c"]="CONFIG_MPTCP_ECF|mptcp-ecf|ECF scheduler"
    ["sched_rr.c"]="CONFIG_MPTCP_RR|mptcp-rr|Round Robin scheduler"
    ["sched_redundant.c"]="CONFIG_MPTCP_REDUNDANT|mptcp-redundant|Redundant scheduler"
)

patch_makefile_kconfig() {
    local cfile="$1" config="$2" obj="$3" desc="$4"
    local objname="${cfile%.c}.o"

    if ! grep -q "$objname" "$MAKEFILE"; then
        echo "obj-\$(${config}) += ${objname}" >> "$MAKEFILE"
        echo "  Makefile: added $objname"
    fi

    local KCONFIG="$SCHED_PATH/Kconfig"
    if ! grep -q "$config" "$KCONFIG"; then
        cat >> "$KCONFIG" <<KCEOF

config ${config#CONFIG_}
	bool "${desc}"
	default y
KCEOF
        echo "  Kconfig: added $config"
    fi
}

for cfile in "${!SCHED_OBJS[@]}"; do
    IFS='|' read -r config obj desc <<< "${SCHED_OBJS[$cfile]}"
    patch_makefile_kconfig "$cfile" "$config" "$obj" "$desc"
done
ok "SCHED-INJECT" "Makefile and Kconfig patched"

# =============================================================================
# STEP 4 — Configure and build the kernel
# =============================================================================
info "KERNEL-BUILD" "Configuring kernel (using current Ubuntu config as base)..."
cd "$KERNEL_SRC"

cp /boot/config-$(uname -r) .config

# Disable cert options that block unsigned kernel builds
scripts/config --disable SYSTEM_TRUSTED_KEYS
scripts/config --disable SYSTEM_REVOCATION_KEYS
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""

# Enable all our schedulers
for cfile in "${!SCHED_OBJS[@]}"; do
    IFS='|' read -r config obj desc <<< "${SCHED_OBJS[$cfile]}"
    scripts/config --enable "${config#CONFIG_}"
done

make olddefconfig

ok "KERNEL-BUILD" "Kernel configured"
info "KERNEL-BUILD" "Building kernel -- this takes 30-90 minutes, please wait..."

make -j$(nproc) 2>&1 | tee /tmp/kernel_build.log \
    || err "KERNEL-BUILD" "Kernel build failed -- check /tmp/kernel_build.log"
ok "KERNEL-BUILD" "Kernel built successfully"

# =============================================================================
# STEP 5 — Install kernel
# =============================================================================
info "KERNEL-INSTALL" "Installing kernel modules and image..."
make modules_install
make install
ok "KERNEL-INSTALL" "Kernel installed -- will activate on next reboot"

# =============================================================================
# STEP 6 — Install Go
# =============================================================================
info "GO" "Installing Go ${GO_VERSION}..."
if command -v go &>/dev/null && go version | grep -q "go${GO_VERSION}"; then
    ok "GO" "Go ${GO_VERSION} already installed"
else
    GO_TAR="go${GO_VERSION}.${GO_ARCH}.tar.gz"
    # Try Pi first (offline), fall back to internet
    if curl -sf "$PI_HOST/payloads/$GO_TAR" -o "/tmp/$GO_TAR" 2>/dev/null; then
        echo "  Downloaded Go from Pi (offline)"
    else
        curl -fL "https://go.dev/dl/$GO_TAR" -o "/tmp/$GO_TAR" \
            || err "GO" "Failed to download Go"
    fi
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/$GO_TAR"
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
    export PATH="$PATH:/usr/local/go/bin"
    ok "GO" "Go ${GO_VERSION} installed"
fi
export PATH="$PATH:/usr/local/go/bin"

# =============================================================================
# STEP 7 — Clone and build mp-quic with novel schedulers
# =============================================================================
info "MPQUIC" "Setting up mp-quic..."

if [[ ! -d "$MPQUIC_DIR/.git" ]]; then
    # Try Pi tarball first, fall back to git clone
    if curl -sf "$PI_HOST/payloads/mp-quic.tar.gz" -o /tmp/mp-quic.tar.gz 2>/dev/null; then
        mkdir -p "$MPQUIC_DIR"
        tar -xzf /tmp/mp-quic.tar.gz -C "$MPQUIC_DIR" --strip-components=1
        ok "MPQUIC" "mp-quic extracted from Pi"
    else
        git clone --depth 1 https://github.com/qdeconinck/mp-quic.git "$MPQUIC_DIR" \
            || err "MPQUIC" "Failed to clone mp-quic"
        ok "MPQUIC" "mp-quic cloned"
    fi
fi

# Ensure it's a git repo (needed for Go VCS checks)
if [[ ! -d "$MPQUIC_DIR/.git" ]]; then
    cd "$MPQUIC_DIR"
    git config --global --add safe.directory "$MPQUIC_DIR"
    git config --global user.email "installer@multirat.local"
    git config --global user.name "Multi-RAT Installer"
    git init
    git add -A
    git commit -m "initial" --quiet
fi

# Write go.mod with pinned dependency versions (from project setup doc)
cat > "$MPQUIC_DIR/go.mod" <<'GOMODEOF'
module github.com/lucas-clemente/quic-go

go 1.20

require (
	github.com/bifurcation/mint v0.0.0-20170726191115-f1bdafed5eee
	github.com/golang/mock v1.6.0
	github.com/hashicorp/golang-lru v1.0.2
	github.com/lucas-clemente/aes12 v0.0.0-20171027163421-cd47fb39b79f
	github.com/lucas-clemente/fnv128a v0.0.0-20160504152609-393af48d3916
	github.com/lucas-clemente/quic-clients v0.1.0
	github.com/lucas-clemente/quic-go-certificates v0.0.0-20160823095156-d2f86524cced
	github.com/onsi/ginkgo v1.16.5
	github.com/onsi/gomega v1.27.0
	golang.org/x/crypto v0.17.0
	golang.org/x/net v0.19.0
)
GOMODEOF

# Patch pconn_manager.go to recognise wlo/wlx/enx interface names
info "MPQUIC" "Patching pconn_manager.go for interface naming..."
PCONN="$MPQUIC_DIR/pconn_manager.go"
if [[ -f "$PCONN" ]] && ! grep -q 'strings.Contains(i.Name, "wlo")' "$PCONN"; then
    sed -i '/strings\.Contains(i\.Name, "lo")/a \\t\t\t\t\&\& !strings.Contains(i.Name, "wlo") \\\n\t\t\t\t\&\& !strings.Contains(i.Name, "wlx") \\\n\t\t\t\t\&\& !strings.Contains(i.Name, "enx")' "$PCONN" \
        || echo "  pconn_manager.go patch may need manual review"
fi

# Copy iperf + ping client/server files from Pi
info "MPQUIC" "Installing iperf/ping client and server..."
mkdir -p "$MPQUIC_DIR/example/iperf_client" "$MPQUIC_DIR/example/iperf_server"
mkdir -p "$MPQUIC_DIR/example/ping_client"  "$MPQUIC_DIR/example/ping_server"

curl -sf "$PI_HOST/payloads/mpquic_clients/iperf/main.go" \
     -o "$MPQUIC_DIR/example/iperf_client/main.go" || true
curl -sf "$PI_HOST/payloads/mpquic_server/iperf/main.go" \
     -o "$MPQUIC_DIR/example/iperf_server/main.go" || true
curl -sf "$PI_HOST/payloads/mpquic_clients/ping/main.go" \
     -o "$MPQUIC_DIR/example/ping_client/main.go" || true
curl -sf "$PI_HOST/payloads/mpquic_server/ping/main.go" \
     -o "$MPQUIC_DIR/example/ping_server/main.go" || true

cd "$MPQUIC_DIR"
export GOFLAGS="-buildvcs=false"
go mod tidy
go build ./... \
    || err "MPQUIC" "mp-quic build failed"
ok "MPQUIC" "mp-quic built successfully"

# Symlink so dashboard backend can find mp-quic at /root/mp-quic
ln -sfn "$MPQUIC_DIR" /root/mp-quic 2>/dev/null || true

# =============================================================================
# STEP 8 — Deploy dashboard
# =============================================================================
info "DASHBOARD" "Deploying dashboard..."
if curl -sf "$PI_HOST/payloads/dashboard.tar.gz" -o /tmp/dashboard.tar.gz 2>/dev/null; then
    rm -rf "$DASHBOARD_DIR"
    mkdir -p "$DASHBOARD_DIR"
    tar -xzf /tmp/dashboard.tar.gz -C "$DASHBOARD_DIR" --strip-components=1
    chmod +x "$DASHBOARD_DIR/start.sh" "$DASHBOARD_DIR/setup_routing.sh" 2>/dev/null || true

    # Install Node.js if missing
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    # Create systemd service with all required environment variables
    cat > /etc/systemd/system/multirat-dashboard.service <<SVCEOF
[Unit]
Description=Multi-RAT Scheduler Dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=$DASHBOARD_DIR
ExecStart=/bin/bash $DASHBOARD_DIR/start.sh
Restart=on-failure
Environment=PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=GOPATH=/root/go
Environment=GOMODCACHE=/root/go/pkg/mod
Environment=HOME=/root
Environment=GOFLAGS=-buildvcs=false

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable multirat-dashboard
    ok "DASHBOARD" "Dashboard deployed and service enabled"
else
    echo "  dashboard.tar.gz not on Pi yet -- run pack_dashboard.sh first"
fi

# =============================================================================
# DONE — reboot required for new kernel
# =============================================================================
echo ""
echo -e "\e[32m============================================\e[0m"
echo -e "\e[32m  Installation complete!\e[0m"
echo -e "\e[32m============================================\e[0m"
echo ""
echo "  The machine will reboot in 10 seconds."
echo "  After reboot:"
echo "    1. Open http://localhost:3000 for the dashboard"
echo "    2. Run 'bash verify.sh' to check all components"
echo ""
echo "  Downloading verification script..."
curl -sf "$PI_HOST/verify.sh" -o /home/*/verify.sh 2>/dev/null || true
# Also save to current user's home
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME=$(eval echo "~$REAL_USER")
curl -sf "$PI_HOST/verify.sh" -o "$REAL_HOME/verify.sh" 2>/dev/null || true
chmod +x "$REAL_HOME/verify.sh" 2>/dev/null || true

sleep 10
reboot
