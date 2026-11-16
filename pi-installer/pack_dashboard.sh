#!/usr/bin/env bash
# =============================================================================
# Pack the dashboard into a tarball for the Pi to serve offline.
# Run this on your LAPTOP (in the project root) before copying to Pi.
#
# Usage:
#   bash pi-installer/pack_dashboard.sh
#
# Output:
#   pi-installer/payloads/dashboard.tar.gz
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$SCRIPT_DIR/payloads/dashboard.tar.gz"

echo "Packing dashboard from $PROJECT_ROOT…"
tar -czf "$OUTPUT" \
    --exclude='node_modules' \
    --exclude='.git' \
    --exclude='pi-installer' \
    --exclude='*.pptx' \
    --exclude='*.pdf' \
    -C "$PROJECT_ROOT" .

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo "✓ Created $OUTPUT ($SIZE)"
echo ""
echo "Next: copy the entire pi-installer/ folder to the Pi:"
echo "  scp -r pi-installer/ <user>@<pi-ip>:~/multirat-installer/"
