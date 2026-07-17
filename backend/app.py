#!/usr/bin/env python3
"""
Multi-RAT dashboard backend.

Runs on the Linux VM that has the MPTCP kernel. Pure Python standard library —
NO pip install needed. Just:  python3 app.py

It exposes the small HTTP API the React Test Runner / Scheduler Dashboard use:

    GET  /health                    -> liveness probe
    GET  /api/schedulers            -> schedulers the kernel supports + current
    GET  /api/scheduler/current     -> the active scheduler
    GET  /api/mpquic/schedulers     -> mp-quic scheduler strategies (from scheduler.go)
    POST /api/mpquic/scheduler      -> edit scheduler.go + `go build ./...` to switch it
    POST /api/mpquic/iperf/start    -> start a multipath mp-quic run (go run iperf_client)

(mp-quic live throughput + result reuse /api/network/throughput and
 /api/iperf/result, since only one run happens at a time.)
    POST /api/scheduler             -> set the active scheduler (sudo sysctl -w)
    POST /api/iperf/start           -> start an iperf3 client run (background)
    GET  /api/network/throughput    -> live overall throughput + finished flag
    GET  /api/iperf/result          -> final iperf3 summary of the last run

Scheduler list / current come straight from the kernel:
    cat /proc/sys/net/mptcp/available_schedulers
    sysctl -n net.mptcp.scheduler

Setting a scheduler runs:
    sudo sysctl -w net.mptcp.scheduler=<name>

Security:
  * The requested scheduler name is validated against the kernel's own
    available list before use, so an arbitrary/injected string can never reach
    the command line.
  * All commands use the argument-list form of subprocess (never shell=True).
  * server_ip / server_port for iperf3 are validated before use.
"""

import json
import os
import re
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AVAILABLE_PATH = "/proc/sys/net/mptcp/available_schedulers"
CURRENT_PATH = "/proc/sys/net/mptcp/scheduler"
SCHEDULER_SYSCTL = "net.mptcp.scheduler"
HOST_RE = re.compile(r"^[A-Za-z0-9.\-]+$")
PORT = 5000

# ---- MPQUIC scheduler discovery -------------------------------------------
# Unlike MPTCP (kernel sysctl), mp-quic selects its scheduler at compile time.
# The available strategies are the selectPath<Name> methods in scheduler.go,
# and the "current" one is whichever selectPath() actually dispatches to. We
# parse that file so the MPQUIC Test Runner can list schedulers dynamically,
# the same way the MPTCP side reads the kernel list.
MPQUIC_DIR = os.environ.get("MPQUIC_DIR", os.path.expanduser("~/mp-quic"))
MPQUIC_SCHEDULER_GO = os.environ.get(
    "MPQUIC_SCHEDULER_GO", os.path.join(MPQUIC_DIR, "scheduler.go"))
MPQUIC_BUILD_TIMEOUT = 300  # seconds for `go build ./...`
SELECTPATH_DEF_RE = re.compile(r"func\s*\(sch\s*\*scheduler\)\s*selectPath([A-Za-z0-9]+)\s*\(")
SELECTPATH_CALL_RE = re.compile(r"return\s+sch\.\s*selectPath([A-Za-z0-9]+)\s*\(")
# The bare selectPath() dispatcher (no <Name> suffix), whose body we rewrite.
SELECTPATH_DISPATCH_RE = re.compile(r"func\s*\(sch\s*\*scheduler\)\s*selectPath\s*\(")

# Interfaces to ignore when discovering mp-quic paths (loopback / virtual);
# mirrors the exclude list in setup_routing.sh.
VIRTUAL_IFACE_RE = re.compile(
    r"^(lo|docker|veth|br-|virbr|vnet|tun|tap|wg|tailscale|zt|kube|cni|flannel|dummy|bond|ifb)")
# iperf-style sender summary printed by example/iperf_client/main.go:
#   [  5]  0.00-60.00  sec  123.45 MBytes  17.26 Mbits/sec  0             sender
MPQUIC_SENDER_RE = re.compile(
    r"([\d.]+)\s+MBytes\s+([\d.]+)\s+(Mbits|Kbits)/sec\s+(\d+)\s+sender")

# ---- shared state for the current / last iperf3 run -----------------------
_run = {
    "active": False,
    "finished": False,
    "result": None,     # final iperf3 summary dict
    "series": [],        # [{t, total_mbps, subflows:{iface:{mbps,rtt}}}] over time
    "latest": None,      # most recent sample
    "ifaces": [],        # interfaces monitored as subflows
}


# ---------------------------------------------------------------------------
# Kernel helpers
# ---------------------------------------------------------------------------
def available_schedulers():
    """Names the kernel advertises, e.g. ['default', 'lrtt', ..., 'noveledf']."""
    with open(AVAILABLE_PATH) as f:
        return f.read().split()


def current_scheduler():
    try:
        with open(CURRENT_PATH) as f:
            return f.read().strip()
    except Exception:
        try:
            out = subprocess.check_output(
                ["sysctl", "-n", SCHEDULER_SYSCTL], text=True, stderr=subprocess.DEVNULL
            )
            return out.strip()
        except Exception:
            return None


def mpquic_schedulers():
    """Parse mp-quic/scheduler.go for its path-selection strategies.

    Returns (names, current):
      names   -> every selectPath<Name> strategy method, in file order
      current -> the strategy the selectPath() dispatcher actually calls
                 (the first uncommented `return sch.selectPath<Name>(...)`)
    """
    with open(MPQUIC_SCHEDULER_GO) as f:
        src = f.read()

    names = []
    for m in SELECTPATH_DEF_RE.finditer(src):
        name = m.group(1)
        if name and name not in names:
            names.append(name)

    current = None
    for line in src.splitlines():
        if line.strip().startswith("//"):        # skip commented-out options
            continue
        cm = SELECTPATH_CALL_RE.search(line)
        if cm:
            current = cm.group(1)
            break

    return names, current


def set_mpquic_scheduler(name):
    """Activate `name` in mp-quic by rewriting the selectPath() dispatcher so its
    `return sch.selectPath<name>(...)` line is the only uncommented one, then
    running `go build ./...`. Returns (ok, error_or_none).

    Only comment markers inside selectPath() are touched — the strategy
    implementations and every other line are left byte-for-byte unchanged.
    """
    try:
        with open(MPQUIC_SCHEDULER_GO) as f:
            src = f.read()
    except FileNotFoundError:
        return False, f"scheduler.go not found at {MPQUIC_SCHEDULER_GO}"

    available = []
    for m in SELECTPATH_DEF_RE.finditer(src):
        if m.group(1) not in available:
            available.append(m.group(1))
    if name not in available:
        return False, f"Unknown scheduler '{name}'"

    lines = src.splitlines(keepends=True)

    # Locate the selectPath() dispatcher body: from its `func ... {` line to the
    # first column-0 `}` (Go's top-level closing brace).
    start = next((i for i, ln in enumerate(lines)
                  if SELECTPATH_DISPATCH_RE.search(ln)), None)
    if start is None:
        return False, "Could not find the selectPath() dispatcher in scheduler.go"
    end = next((j for j in range(start + 1, len(lines))
                if lines[j].rstrip("\n") == "}"), None)
    if end is None:
        return False, "Could not find the end of selectPath()"

    found_target = False
    for k in range(start + 1, end):
        line = lines[k]
        eol = "\n" if line.endswith("\n") else ""
        body = line[:-len(eol)] if eol else line
        m = SELECTPATH_CALL_RE.search(body)
        if not m:
            continue
        this_name = m.group(1)
        indent = body[:len(body) - len(body.lstrip())]
        stripped = body.strip()
        code = stripped[2:].strip() if stripped.startswith("//") else stripped
        if this_name == name:
            lines[k] = indent + code + eol            # uncomment the chosen one
            found_target = True
        else:
            lines[k] = indent + "// " + code + eol     # comment out the rest

    if not found_target:
        return False, (f"selectPath() has no `return sch.selectPath{name}(...)` line "
                       f"to enable — add one there first.")

    try:
        with open(MPQUIC_SCHEDULER_GO, "w") as f:
            f.writelines(lines)
    except OSError as e:
        return False, f"Failed to write scheduler.go: {e}"

    if not shutil.which("go"):
        return False, "scheduler.go updated, but `go` is not installed to build it"
    try:
        proc = subprocess.run(["go", "build", "./..."], cwd=MPQUIC_DIR,
                              capture_output=True, text=True,
                              timeout=MPQUIC_BUILD_TIMEOUT)
    except subprocess.TimeoutExpired:
        return False, f"go build timed out after {MPQUIC_BUILD_TIMEOUT}s"
    except OSError as e:
        return False, f"Could not run go build: {e}"
    if proc.returncode != 0:
        return False, (proc.stderr or proc.stdout or "go build failed").strip()
    return True, None


def set_scheduler(name):
    """Apply a scheduler. Returns (ok, error_or_none). Validates name first."""
    try:
        allowed = available_schedulers()
    except FileNotFoundError:
        return False, "MPTCP not available on this kernel"
    if name not in allowed:
        return False, f"Unknown scheduler '{name}'"
    try:
        subprocess.run(
            ["sudo", "sysctl", "-w", f"{SCHEDULER_SYSCTL}={name}"],
            check=True, capture_output=True, text=True,
        )
    except subprocess.CalledProcessError as e:
        return False, (e.stderr or str(e)).strip()
    return True, None


# ---------------------------------------------------------------------------
# Per-subflow monitoring helpers
#
# MPTCP is transparent at the socket layer, so iperf3's own JSON only reports
# the aggregate connection. Per-subflow numbers therefore come from the kernel:
#   throughput -> per-interface tx byte counters in /sys/class/net/<i>/statistics
#                 (each subflow rides a different interface; iperf3 -c uploads,
#                  so tx bytes on an interface ≈ that subflow's throughput)
#   RTT        -> `ss -tin dst <server>` reports rtt per TCP subflow; we map each
#                 subflow to its interface by its local IP.
# (Interface throughput approach follows Signal-Logger-V2/network_utils.py.)
# ---------------------------------------------------------------------------
def subflow_ifaces():
    """Interfaces carrying MPTCP subflows: configured endpoints + the default
    route interface. Falls back to every non-loopback interface."""
    ifaces = set()
    try:
        out = subprocess.check_output(["ip", "mptcp", "endpoint", "show"],
                                      text=True, stderr=subprocess.DEVNULL)
        ifaces.update(re.findall(r"dev (\S+)", out))
    except Exception:
        pass
    try:
        out = subprocess.check_output(["ip", "route", "show", "default"],
                                      text=True, stderr=subprocess.DEVNULL)
        m = re.search(r"dev (\S+)", out)
        if m:
            ifaces.add(m.group(1))
    except Exception:
        pass
    ifaces = [i for i in ifaces if os.path.isdir(f"/sys/class/net/{i}")]
    if not ifaces:
        ifaces = [i for i in os.listdir("/sys/class/net") if i != "lo"]
    return sorted(ifaces)


def mpquic_ifaces():
    """Interfaces that can carry mp-quic paths: every interface with a global
    IPv4 address, minus loopback/virtual ones. Matches setup_routing.sh, since
    those are exactly the links policy routing makes usable. mp-quic is UDP, so
    unlike MPTCP there's no kernel subflow list — the physical interfaces are
    the paths, and their tx_bytes give per-path throughput."""
    ifaces = []
    try:
        out = subprocess.check_output(
            ["ip", "-o", "-4", "addr", "show", "up", "scope", "global"],
            text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and not VIRTUAL_IFACE_RE.match(parts[1]):
                if parts[1] not in ifaces:
                    ifaces.append(parts[1])
    except Exception:
        pass
    if not ifaces:
        ifaces = [i for i in os.listdir("/sys/class/net") if i != "lo"]
    return sorted(ifaces)


def _iface_tx_bytes(iface):
    with open(f"/sys/class/net/{iface}/statistics/tx_bytes") as f:
        return int(f.read())


def _iface_ip_map():
    """Map local IPv4 -> interface name, used to attribute subflow RTT."""
    mapping = {}
    try:
        out = subprocess.check_output(["ip", "-o", "-4", "addr", "show"],
                                      text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[2] == "inet":
                mapping[parts[3].split("/")[0]] = parts[1]
    except Exception:
        pass
    return mapping


def _subflow_rtts(server_ip, ip_map):
    """Per-interface RTT (ms) of the TCP subflows to server_ip, via `ss`."""
    try:
        out = subprocess.check_output(["ss", "-tin", "dst", server_ip],
                                      text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return {}
    rtts, local_ip = {}, None
    for line in out.splitlines():
        m = re.search(r"\s(\d+\.\d+\.\d+\.\d+):\d+\s+\d+\.\d+\.\d+\.\d+:\d+", line)
        if m:
            local_ip = m.group(1)
            continue
        mr = re.search(r"\brtt:([0-9.]+)/", line)
        if mr and local_ip:
            iface = ip_map.get(local_ip)
            if iface:
                rtts.setdefault(iface, []).append(float(mr.group(1)))
            local_ip = None
    return {k: round(sum(v) / len(v), 2) for k, v in rtts.items()}


def _sampler(server_ip, ifaces):
    """Once a second while a run is active, record per-subflow throughput + RTT."""
    ip_map = _iface_ip_map()
    prev = {i: _iface_tx_bytes(i) for i in ifaces}
    prev_t = time.time()
    t = 0
    while _run["active"]:
        time.sleep(1)
        now = time.time()
        dt = now - prev_t
        prev_t = now
        t += 1
        rtts = _subflow_rtts(server_ip, ip_map)
        subflows, total = {}, 0.0
        for i in ifaces:
            try:
                cur = _iface_tx_bytes(i)
            except Exception:
                continue
            mbps = round((cur - prev[i]) * 8 / 1e6 / dt, 2) if dt > 0 else 0.0
            prev[i] = cur
            mbps = max(mbps, 0.0)
            subflows[i] = {"mbps": mbps, "rtt": rtts.get(i)}
            total += mbps
        sample = {"t": t, "total_mbps": round(total, 2), "subflows": subflows}
        _run["series"].append(sample)
        _run["latest"] = sample


# ---------------------------------------------------------------------------
# iperf3 run (over MPTCP via mptcpize)
# ---------------------------------------------------------------------------
def _iperf_error(server_ip, server_port, duration, msg):
    return {
        "duration": duration,
        "target": f"{server_ip}:{server_port}",
        "throughput_mbps": 0,
        "retransmits": 0,
        "subflows": _run["ifaces"],
        "error": msg,
    }


def _run_iperf(server_ip, server_port, duration):
    # The MPTCP command the project uses, in JSON mode for parsing:
    #   mptcpize run iperf3 -c <ip> -t <time> -p <port> --connect-timeout 8000 -J
    # --connect-timeout means an unreachable server fails in ~8s instead of the
    # client hanging on the control connection (which looks like "no traffic").
    cmd = ["mptcpize", "run", "iperf3", "-c", server_ip,
           "-t", str(duration), "-p", str(server_port),
           "--connect-timeout", "8000", "-J"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=duration + 20)
        data = json.loads(proc.stdout or "{}")
        if "error" in data:                    # iperf3 reports failures in JSON
            raise RuntimeError(data["error"])
        end = data.get("end", {})
        sent = end.get("sum_sent", {}) or end.get("sum", {})
        _run["result"] = {
            "duration": duration,
            "target": f"{server_ip}:{server_port}",
            "throughput_mbps": round(sent.get("bits_per_second", 0) / 1e6, 2),
            "retransmits": sent.get("retransmits", 0),
            "subflows": _run["ifaces"],
        }
    except subprocess.TimeoutExpired:
        _run["result"] = _iperf_error(
            server_ip, server_port, duration,
            f"iperf3 did not finish within {duration + 20}s — is the server "
            f"running at {server_ip}:{server_port}?")
    except Exception as e:  # connection refused/timeout, bad JSON, etc.
        _run["result"] = _iperf_error(server_ip, server_port, duration, str(e))
    finally:
        _run["finished"] = True
        _run["active"] = False


def start_iperf(server_ip, server_port, duration):
    """Validate + launch the MPTCP iperf3 run and the subflow sampler."""
    if not HOST_RE.match(server_ip or ""):
        return 400, {"ok": False, "error": "Invalid server_ip"}
    if not (1 <= server_port <= 65535):
        return 400, {"ok": False, "error": "server_port out of range"}
    if not (1 <= duration <= 3600):
        return 400, {"ok": False, "error": "duration out of range"}
    if not shutil.which("iperf3"):
        return 500, {"ok": False, "error": "iperf3 is not installed on the backend"}
    if not shutil.which("mptcpize"):
        return 500, {"ok": False, "error": "mptcpize is not installed on the backend"}
    if _run["active"]:
        return 409, {"ok": False, "error": "A test is already running"}

    ifaces = subflow_ifaces()
    _run.update(active=True, finished=False, result=None,
                series=[], latest=None, ifaces=ifaces)
    threading.Thread(target=_run_iperf, args=(server_ip, server_port, duration),
                     daemon=True).start()
    threading.Thread(target=_sampler, args=(server_ip, ifaces), daemon=True).start()
    return 200, {"ok": True}


# ---------------------------------------------------------------------------
# mp-quic run (multipath QUIC via the example iperf client)
#
#   go run example/iperf_client/main.go -addr <ip>:<port> -t <dur> -multipath
#
# Per-path throughput comes from the same per-interface tx_bytes sampler used
# for MPTCP (mp-quic is UDP; each path rides a physical interface). The overall
# summary (throughput + retransmits) is parsed from the client's sender line.
# ---------------------------------------------------------------------------
MPQUIC_IPERF_MAIN = os.path.join("example", "iperf_client", "main.go")


def _run_mpquic_iperf(server_ip, server_port, duration):
    cmd = ["go", "run", MPQUIC_IPERF_MAIN,
           "-addr", f"{server_ip}:{server_port}",
           "-t", str(duration), "-multipath"]
    try:
        # `go run` compiles first, so allow generous headroom over the duration.
        proc = subprocess.run(cmd, cwd=MPQUIC_DIR, capture_output=True, text=True,
                              timeout=duration + 120)
        out = proc.stdout or ""
        m = MPQUIC_SENDER_RE.search(out)
        if m:
            mbps = float(m.group(2))
            if m.group(3) == "Kbits":
                mbps /= 1000.0
            _run["result"] = {
                "duration": duration,
                "target": f"{server_ip}:{server_port}",
                "throughput_mbps": round(mbps, 2),
                "retransmits": int(m.group(4)),
                "subflows": _run["ifaces"],
            }
        else:
            # No summary line -> connection failure or a build error. Surface the
            # most useful line we have.
            tail = (out.strip().splitlines() or [""])[-1]
            msg = tail or (proc.stderr or "mp-quic client produced no summary").strip()
            _run["result"] = _iperf_error(server_ip, server_port, duration,
                                          msg.strip()[:300])
    except subprocess.TimeoutExpired:
        _run["result"] = _iperf_error(
            server_ip, server_port, duration,
            f"mp-quic client did not finish within {duration + 120}s — is the "
            f"server running at {server_ip}:{server_port}?")
    except Exception as e:
        _run["result"] = _iperf_error(server_ip, server_port, duration, str(e))
    finally:
        _run["finished"] = True
        _run["active"] = False


def start_mpquic_iperf(server_ip, server_port, duration):
    """Validate + launch the mp-quic multipath run and the per-interface sampler."""
    if not HOST_RE.match(server_ip or ""):
        return 400, {"ok": False, "error": "Invalid server_ip"}
    if not (1 <= server_port <= 65535):
        return 400, {"ok": False, "error": "server_port out of range"}
    if not (1 <= duration <= 3600):
        return 400, {"ok": False, "error": "duration out of range"}
    if not shutil.which("go"):
        return 500, {"ok": False, "error": "go is not installed on the backend"}
    if not os.path.isfile(os.path.join(MPQUIC_DIR, MPQUIC_IPERF_MAIN)):
        return 500, {"ok": False,
                     "error": f"mp-quic iperf client not found at {MPQUIC_DIR}/{MPQUIC_IPERF_MAIN}"}
    if _run["active"]:
        return 409, {"ok": False, "error": "A test is already running"}

    ifaces = mpquic_ifaces()
    _run.update(active=True, finished=False, result=None,
                series=[], latest=None, ifaces=ifaces)
    threading.Thread(target=_run_mpquic_iperf, args=(server_ip, server_port, duration),
                     daemon=True).start()
    threading.Thread(target=_sampler, args=(server_ip, ifaces), daemon=True).start()
    return 200, {"ok": True}


def network_throughput():
    """Latest live sample: overall + per-subflow throughput and RTT."""
    latest = _run["latest"] or {"t": 0, "total_mbps": 0, "subflows": {}}
    return {
        "t": latest["t"],
        "total_mbps": latest["total_mbps"],
        "subflows": latest["subflows"],
        "ifaces": _run["ifaces"],
        "finished": _run["finished"],
    }


# ---------------------------------------------------------------------------
# HTTP routing
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "MultiRAT/1.0"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204, {})

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        elif self.path == "/api/schedulers":
            try:
                self._send(200, {"schedulers": available_schedulers(),
                                  "current": current_scheduler()})
            except FileNotFoundError:
                self._send(500, {"error": "MPTCP schedulers not available on this kernel",
                                 "schedulers": []})
        elif self.path == "/api/scheduler/current":
            self._send(200, {"current": current_scheduler()})
        elif self.path == "/api/mpquic/schedulers":
            try:
                names, current = mpquic_schedulers()
                if not names:
                    raise RuntimeError("no selectPath strategies found in scheduler.go")
                self._send(200, {"schedulers": names, "current": current})
            except FileNotFoundError:
                self._send(500, {"error": f"mp-quic scheduler.go not found at {MPQUIC_SCHEDULER_GO}",
                                 "schedulers": []})
            except Exception as e:
                self._send(500, {"error": str(e), "schedulers": []})
        elif self.path == "/api/network/throughput":
            self._send(200, network_throughput())
        elif self.path == "/api/iperf/result":
            self._send(200, _run["result"] or {})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            data = {}

        if self.path == "/api/scheduler":
            ok, err = set_scheduler(str(data.get("scheduler", "")).strip())
            if ok:
                self._send(200, {"ok": True, "current": current_scheduler()})
            else:
                self._send(400 if "Unknown" in (err or "") else 500,
                           {"ok": False, "error": err})
        elif self.path == "/api/mpquic/scheduler":
            ok, err = set_mpquic_scheduler(str(data.get("scheduler", "")).strip())
            if ok:
                self._send(200, {"ok": True, "current": mpquic_schedulers()[1]})
            else:
                self._send(400 if "Unknown" in (err or "") else 500,
                           {"ok": False, "error": err})
        elif self.path == "/api/iperf/start":
            try:
                ip = str(data.get("server_ip", "")).strip()
                port = int(data.get("server_port", 5201))
                dur = int(data.get("duration", 10))
            except (TypeError, ValueError):
                self._send(400, {"ok": False, "error": "duration and server_port must be integers"})
                return
            code, body = start_iperf(ip, port, dur)
            self._send(code, body)
        elif self.path == "/api/mpquic/iperf/start":
            try:
                ip = str(data.get("server_ip", "")).strip()
                port = int(data.get("server_port", 6121))
                dur = int(data.get("duration", 10))
            except (TypeError, ValueError):
                self._send(400, {"ok": False, "error": "duration and server_port must be integers"})
                return
            code, body = start_mpquic_iperf(ip, port, dur)
            self._send(code, body)
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        # Keep the console quiet except for a compact request line.
        # flush=True so requests show up immediately (stdout is block-buffered
        # when not attached to a terminal).
        print(f"[{self.log_date_time_string()}] {self.command} {self.path}", flush=True)


if __name__ == "__main__":
    print(f"Multi-RAT backend listening on http://0.0.0.0:{PORT}", flush=True)
    try:
        print("Kernel schedulers:", " ".join(available_schedulers()), flush=True)
        print("Active scheduler:", current_scheduler(), flush=True)
    except FileNotFoundError:
        print("WARNING: MPTCP schedulers not found — is this an MPTCP kernel?", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
