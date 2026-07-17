# Dashboard backend

Runs on the **Linux host that has the MPTCP kernel**. Pure Python standard
library (no pip install). It backs the React Test Runner and Scheduler
Dashboard: it reads the schedulers the kernel supports, switches the active
scheduler, and runs MPTCP iperf3 while monitoring per-subflow throughput + RTT.

## Endpoints

| Method | Path                       | What it does                                                        |
|--------|----------------------------|--------------------------------------------------------------------|
| GET    | `/health`                  | Liveness probe.                                                     |
| GET    | `/api/schedulers`          | `cat /proc/sys/net/mptcp/available_schedulers` + current scheduler. |
| GET    | `/api/scheduler/current`   | The active scheduler (`sysctl -n net.mptcp.scheduler`).            |
| POST   | `/api/scheduler`           | `sudo sysctl -w net.mptcp.scheduler=<name>` (name validated).      |
| POST   | `/api/iperf/start`         | Start an MPTCP run: `mptcpize run iperf3 -c <ip> -t <dur> -p <port> -J`, plus a per-subflow sampler. |
| GET    | `/api/network/throughput`  | Latest live sample: overall + per-subflow Mbps/RTT + `finished`.   |
| GET    | `/api/iperf/result`        | Final iperf3 summary (overall throughput, retransmits, subflows).  |

## How per-subflow monitoring works

MPTCP is transparent at the socket layer, so iperf3's own JSON only reports the
aggregate connection. Per-subflow numbers come from the kernel while the run is
in progress (sampled once a second):

- **Throughput per subflow** — each subflow rides a different interface, so the
  per-interface tx byte counters in `/sys/class/net/<iface>/statistics/tx_bytes`
  give each subflow's rate (iperf3 `-c` uploads, so tx ≈ subflow throughput).
  This mirrors the approach in `Signal-Logger-V2/network_utils.py`.
- **RTT per subflow** — `ss -tin dst <server>` reports the smoothed RTT of every
  TCP subflow to the server; each subflow is matched to its interface by its
  local IP (`ip -o -4 addr`).
- **Which interfaces** — the MPTCP endpoints (`ip mptcp endpoint show`) plus the
  default-route interface; falls back to all non-loopback interfaces.

## Run it

No dependencies to install — it uses only the Python standard library:

```bash
cd backend
python3 app.py            # listens on 0.0.0.0:5000
```

Then set `BACKEND_URL` in `frontend/src/pages/TestRunnerPage.js`:

- Frontend and backend on the **same machine** → `http://localhost:5000` (the default).
- Backend on a **separate VM** → that VM's address, e.g. `http://192.168.147.130:5000`.

When the frontend can reach it, the scheduler dropdown fills from the kernel and
switches to **Live mode**; otherwise it falls back to the built-in list and
**Demo mode**.

## sudo for setting the scheduler

`POST /api/scheduler` calls `sudo sysctl -w`. So it can run without a password
prompt, give the account running the backend a passwordless rule for that one
command:

```bash
# /etc/sudoers.d/mptcp-scheduler  (edit with: sudo visudo -f /etc/sudoers.d/mptcp-scheduler)
van ALL=(root) NOPASSWD: /usr/sbin/sysctl -w net.mptcp.scheduler=*
```

Then `sudo chmod 440 /etc/sudoers.d/mptcp-scheduler`. Replace `van` with the
account running the backend and adjust the path to match `which sysctl` if it
differs. Verify with:

```bash
sudo -n /usr/sbin/sysctl -w net.mptcp.scheduler=lrtt   # should not prompt for a password
```

Running the backend as root also works, but the scoped sudoers rule is safer.

## Requirements on the VM

- An MPTCP-capable kernel exposing `/proc/sys/net/mptcp/available_schedulers`.
- `iperf3` and `mptcpize` installed (`sudo apt install iperf3 mptcpize`), and an
  iperf3 **server** reachable at the IP/port you enter in the Test Runner
  (`iperf3 -s` on the target).
- `ss` and `ip` (from `iproute2`, normally already present) — used for per-subflow
  RTT and interface discovery.
