#!/usr/bin/env bash
# =============================================================================
# Payload Preparation Script
# Run this on your LAPTOP (with internet) before copying the installer to the Pi.
# Downloads everything the target machine will need so the install works offline.
#
# Usage (in Git Bash, WSL, or any Linux terminal):
#   bash pi-installer/prep_payloads.sh
#
# What this downloads/creates:
#   payloads/go1.20.14.linux-amd64.tar.gz   <- for x86_64 ship machines
#   payloads/go1.20.14.linux-arm64.tar.gz    <- for ARM machines
#   payloads/mp-quic.tar.gz                  <- mp-quic repo (pre-cloned)
#   payloads/dashboard.tar.gz               <- the dashboard (packed)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOADS="$SCRIPT_DIR/payloads"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GO_VERSION="1.20.14"
MPQUIC_REPO="https://github.com/qdeconinck/mp-quic.git"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC}  $1"; }
info() { echo -e "${YELLOW}→${NC}  $1"; }

echo ""
echo "============================================"
echo "  Multi-RAT Payload Preparation"
echo "============================================"
echo ""

# ── 1. Go tarballs ────────────────────────────────────────────────────────────
for ARCH in linux-amd64 linux-arm64; do
    FNAME="go${GO_VERSION}.${ARCH}.tar.gz"
    DEST="$PAYLOADS/$FNAME"

    if [[ -f "$DEST" ]]; then
        ok "$FNAME already exists — skipping"
    else
        info "Downloading Go ${GO_VERSION} for ${ARCH}…"
        curl -fL "https://go.dev/dl/$FNAME" -o "$DEST"
        ok "Downloaded $FNAME ($(du -sh "$DEST" | cut -f1))"
    fi
done

# ── 2. mp-quic repo ───────────────────────────────────────────────────────────
MPQUIC_TAR="$PAYLOADS/mp-quic.tar.gz"
if [[ -f "$MPQUIC_TAR" ]]; then
    ok "mp-quic.tar.gz already exists — skipping"
else
    info "Cloning mp-quic repository…"
    TMP_MPQUIC=$(mktemp -d)
    git clone --depth 1 "$MPQUIC_REPO" "$TMP_MPQUIC/mp-quic"
    info "Creating mp-quic.tar.gz…"
    tar -czf "$MPQUIC_TAR" -C "$TMP_MPQUIC" mp-quic
    rm -rf "$TMP_MPQUIC"
    ok "Created mp-quic.tar.gz ($(du -sh "$MPQUIC_TAR" | cut -f1))"
fi

# ── 3. Dashboard tarball ──────────────────────────────────────────────────────
DASHBOARD_TAR="$PAYLOADS/dashboard.tar.gz"
info "Packing dashboard…"
tar -czf "$DASHBOARD_TAR" \
    --exclude='node_modules' \
    --exclude='.git' \
    --exclude='pi-installer' \
    --exclude='*.pptx' \
    --exclude='*.pdf' \
    --exclude='*.png' \
    -C "$PROJECT_ROOT" .
ok "Created dashboard.tar.gz ($(du -sh "$DASHBOARD_TAR" | cut -f1))"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  All payloads ready!"
echo ""
echo "  Contents of payloads/:"
ls -lh "$PAYLOADS"/*.tar.gz "$PAYLOADS"/*.gz 2>/dev/null | awk '{print "  "$NF, $5}'
echo ""
echo "  Next step — copy installer to Pi:"
echo "  scp -r $SCRIPT_DIR adil@multirat-pi.local:~/multirat-installer/"
echo "============================================"
echo ""
