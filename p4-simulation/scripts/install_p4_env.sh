#!/bin/bash
# ============================================================================
# P4 + BMv2 + Mininet Environment Setup
# For Ubuntu 22.04 / 24.04 LTS
#
# Installs:
#   - Mininet (network emulation)
#   - BMv2 (P4 behavioral model / software switch)
#   - p4c (P4 compiler)
#   - p4-utils or p4app helpers
#
# Usage:  sudo bash install_p4_env.sh
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    err "Please run as root: sudo bash $0"
fi

INSTALL_DIR="/opt/p4-tools"
mkdir -p "$INSTALL_DIR"

# ── Step 1: System dependencies ─────────────────────────────────────────────
log "Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq \
    git automake cmake libtool g++ libgc-dev bison flex \
    libfl-dev libboost-dev libboost-iostreams-dev libboost-graph-dev \
    llvm pkg-config python3-pip python3-setuptools python3-wheel \
    libgmp-dev libpcap-dev tcpdump iperf3 net-tools curl \
    libreadline-dev valgrind libevent-dev libssl-dev \
    libnanomsg-dev libprotobuf-dev protobuf-compiler protobuf-compiler-grpc \
    libgrpc-dev libgrpc++-dev libabsl-dev \
    python3-protobuf python3-scapy python3-psutil \
    mininet openvswitch-switch 2>/dev/null || true

# ── Step 1b: Check gRPC (build from source if apt packages didn't work) ────
if ! pkg-config --exists grpc++ 2>/dev/null; then
    warn "gRPC not found via pkg-config — building from source..."
    cd /tmp
    if [ ! -d grpc ]; then
        git clone --depth 1 --branch v1.43.0 https://github.com/grpc/grpc.git
        cd grpc
        git submodule update --init --depth 1
    else
        cd grpc
    fi
    mkdir -p cmake/build && cd cmake/build
    cmake ../.. \
        -DgRPC_INSTALL=ON \
        -DgRPC_BUILD_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_BUILD_TYPE=Release \
        -DgRPC_PROTOBUF_PROVIDER=package \
        -DgRPC_SSL_PROVIDER=package
    make -j$(nproc)
    make install
    ldconfig
    log "gRPC built and installed from source."
else
    log "gRPC already available via pkg-config."
fi

# ── Step 2: PI (Protocol Independent library) ───────────────────────────────
if [ ! -d "$INSTALL_DIR/PI" ]; then
    log "Cloning PI (Protocol Independent)..."
    cd "$INSTALL_DIR"
    git clone --depth 1 https://github.com/p4lang/PI.git
    cd PI
    git submodule update --init --recursive
    ./autogen.sh
    ./configure --with-proto
    make -j$(nproc)
    make install
    ldconfig
    log "PI installed."
else
    log "PI already installed, skipping."
fi

# ── Step 3: BMv2 (Behavioral Model v2) ──────────────────────────────────────
if ! command -v simple_switch &>/dev/null; then
    log "Installing BMv2 (software P4 switch)..."
    cd "$INSTALL_DIR"
    if [ ! -d behavioral-model ]; then
        git clone --depth 1 https://github.com/p4lang/behavioral-model.git
    fi
    cd behavioral-model
    ./install_deps.sh
    ./autogen.sh
    ./configure --enable-debugger --with-pi
    make -j$(nproc)
    make install
    ldconfig
    log "BMv2 installed."
else
    log "BMv2 (simple_switch) already installed, skipping."
fi

# ── Step 4: p4c (P4 Compiler) ───────────────────────────────────────────────
if ! command -v p4c &>/dev/null; then
    log "Installing p4c (P4 compiler)..."
    cd "$INSTALL_DIR"
    if [ ! -d p4c ]; then
        git clone --depth 1 --recursive https://github.com/p4lang/p4c.git
    fi
    cd p4c
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j$(nproc)
    make install
    ldconfig
    log "p4c installed."
else
    log "p4c already installed, skipping."
fi

# ── Step 5: Python helpers ──────────────────────────────────────────────────
log "Installing Python helpers..."
pip3 install --break-system-packages \
    mininet psutil scapy matplotlib pandas 2>/dev/null || \
pip3 install mininet psutil scapy matplotlib pandas

# ── Step 6: p4-utils (Mininet + P4 integration) ────────────────────────────
if [ ! -d "$INSTALL_DIR/p4-utils" ]; then
    log "Installing p4-utils (Mininet-P4 integration)..."
    cd "$INSTALL_DIR"
    git clone --depth 1 https://github.com/nsg-ethz/p4-utils.git
    cd p4-utils
    pip3 install --break-system-packages . 2>/dev/null || pip3 install .
    log "p4-utils installed."
else
    log "p4-utils already installed, skipping."
fi

# ── Step 7: Verify ──────────────────────────────────────────────────────────
log "Verifying installation..."
echo ""
echo "=== P4 Environment Check ==="

check() {
    if command -v "$1" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $1 found: $(command -v $1)"
    else
        echo -e "  ${RED}✗${NC} $1 NOT found"
    fi
}

check simple_switch
check p4c
check mn

echo ""
log "Installation complete!"
echo ""
echo "Quick test:  sudo mn --test pingall"
echo "P4 compile:  p4c --target bmv2 --arch v1model your_program.p4"
echo ""
