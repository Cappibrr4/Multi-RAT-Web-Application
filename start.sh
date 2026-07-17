#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Start the dashboard: launches the backend and the frontend together.
#
#   ./start.sh
#
# The backend (python3 backend/app.py) runs in the background; the frontend
# (npm start) runs in the foreground. When you stop the dashboard — Ctrl+C, or
# closing the terminal — the trap below shuts the backend down too, so the two
# always start and stop together.
#
# Note: this is for the Linux host that has the MPTCP kernel (the backend reads
# /proc/sys/net/mptcp/...). On a machine without it the backend just reports no
# schedulers and the frontend falls back to Demo mode.
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "$0")"

BACKEND_PID=""

cleanup() {
    if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo ""
        echo "Stopping backend (pid $BACKEND_PID)..."
        kill "$BACKEND_PID" 2>/dev/null || true
        wait "$BACKEND_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Ensure mp-quic policy routing is in place (idempotent). Interfaces that reset
# can come back with a new IP, so this is re-checked on every start. Needs sudo;
# running here in the terminal lets it prompt if necessary.
if [[ -f setup_routing.sh ]]; then
    bash setup_routing.sh || echo "WARNING: routing setup reported an issue (continuing)."
fi

# Free port 5000 from any backend left over from a previous run.
pkill -f "backend/app.py" 2>/dev/null || true
sleep 0.5

echo "Starting backend  -> http://localhost:5000"
python3 backend/app.py &
BACKEND_PID=$!

# Give the backend a moment, then confirm it came up.
sleep 1
if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    echo "ERROR: backend failed to start (see output above)." >&2
    exit 1
fi

echo "Starting frontend -> http://localhost:3000  (Ctrl+C here stops both)"
echo ""
# Frontend runs in the foreground; when it exits, the EXIT trap stops the backend.
npm --prefix frontend start
