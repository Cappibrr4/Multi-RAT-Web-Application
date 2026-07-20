# Multi-RAT Web Application — Multipath Scheduler Dashboard

A full-stack web dashboard for designing, switching, and benchmarking packet schedulers across two multipath transport protocols: **MPTCP** and **MPQUIC**. The React frontend visualises live throughput and per-subflow metrics; the Python backend drives the Linux kernel and the mp-quic stack.

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Schedulers](#schedulers)
   - [MPTCP Schedulers](#mptcp-schedulers)
   - [MPQUIC Schedulers](#mpquic-schedulers)
4. [Project Structure](#project-structure)
5. [Prerequisites](#prerequisites)
6. [Installation](#installation)
7. [Running the Application](#running-the-application)
   - [Linux (Ubuntu VM — full mode)](#linux-ubuntu-vm--full-mode)
   - [Windows (frontend only / demo mode)](#windows-frontend-only--demo-mode)
8. [Backend API Reference](#backend-api-reference)
9. [Dashboard Pages](#dashboard-pages)
10. [Sudo Configuration for Scheduler Switching](#sudo-configuration-for-scheduler-switching)
11. [Demo Mode](#demo-mode)
12. [Development Notes](#development-notes)

---

## Project Overview

This project designs and evaluates packet schedulers for two multipath transport protocols. A scheduler decides, for every unit of data, which network path carries it. The dashboard provides:

- A **Home** page describing every scheduler's algorithm and formula
- An **MPTCP Benchmark** page to run live `iperf3` tests and switch kernel schedulers
- An **MPQUIC Benchmark** page to run live `mp-quic` multipath tests and switch QUIC schedulers
- A **Scheduler Dashboard** to compare results across runs with per-subflow throughput and RTT breakdown

Three novel MPTCP schedulers (Hybrid, CWL2, EDF2) and one novel MPQUIC scheduler (BWA) were designed and implemented as part of this project.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│              React Frontend                 │
│  (HomePage, TestRunnerPage,                 │
│   MpquicTestRunnerPage,                     │
│   SchedulerDashboardPage)                   │
│                  │                          │
│         http://localhost:3000               │
└──────────────────┬──────────────────────────┘
                   │ REST (JSON)
                   ▼
┌─────────────────────────────────────────────┐
│           Python Backend (port 5000)        │
│           backend/app.py                    │
│     Pure stdlib — no pip install needed     │
│                  │                          │
│    ┌─────────────┴──────────────┐           │
│    │                            │           │
│  MPTCP                       MPQUIC         │
│  /proc/sys/net/mptcp/...    ~/mp-quic/      │
│  mptcpize + iperf3          go run          │
└─────────────────────────────────────────────┘
```

The backend must run on a **Linux host with an MPTCP-capable kernel**. The frontend can run on any machine with Node.js; if the backend is unreachable it automatically falls back to **Demo mode** with simulated data.

---

## Schedulers

### MPTCP Schedulers

| Scheduler | Tag | Novel |
|-----------|-----|-------|
| Default | minimum linger time | |
| Round Robin | rrpacket | |
| LRTT | lowest RTT first | |
| Redundant | all paths | |
| BLEST | blocking estimation | |
| ECF | earliest completion first | |
| **Hybrid** | RTT linger | ✅ |
| **CWL2** | congestion weighted linger | ✅ |
| **EDF2** | earliest delivery first | ✅ |

**Hybrid** multiplies the default linger term by an explicit RTT factor so latency counts for more. Because the pacing rate already contains RTT, this squares the RTT effect — which motivated the CWL2 design.

**CWL2 (Congestion-Weighted Linger)** keeps the default linger term and multiplies it by a weight reflecting how full the congestion window is, nudging new data toward less-busy paths. RTT stays implicit in the pacing rate, so there is no RTT squaring. When a path is idle the weight is 1, so CWL2 cannot regress below the default.

```
score = ((wmem << 32) / pace) × (SCALE + fill × ALPHA) / SCALE
```

**EDF2 (Earliest-Delivery-First, revision 2)** estimates the delivery time of the next segment on each subflow — roughly `srtt/2` if the window has room, or `srtt × 1.5` if it is full — and picks the subflow with the earliest delivery. Revision 2 separates the head-of-line blocking guard from path selection using MinRTT as the reference, so the scheduler correctly returns to a path after a transient RTT spike.

```
delivery ≈ srtt / 2  (window free)  or  srtt × 1.5  (window full)
```

---

### MPQUIC Schedulers

| Scheduler | Tag | Novel |
|-----------|-----|-------|
| Round Robin | lowest quota | |
| Low Latency | lowest RTT | |
| **BWA** | bandwidth weighted arrival | ✅ |

**BWA (Bandwidth-Weighted Arrival)** estimates how long a new packet would take to arrive on each path — the time to drain the in-flight queue at the path's current delivery rate (`cwnd/srtt`) plus half an RTT of propagation. A stickiness margin keeps traffic on the current path unless a challenger is clearly better, avoiding unnecessary path flapping. A head-of-line blocking guard skips any path whose smoothed RTT exceeds 3× the fastest path's minimum RTT.

```
arrival = inflight / (cwnd / srtt) + srtt / 2
```

---

## Project Structure

```
Multi-RAT-Web-Application/
│
├── backend/
│   ├── app.py              # Python HTTP server (stdlib only, port 5000)
│   └── README.md           # Backend-specific documentation
│
├── frontend/
│   ├── public/
│   │   └── index.html
│   ├── src/
│   │   ├── components/
│   │   │   ├── NavBar.js
│   │   │   └── NavBar.css
│   │   ├── pages/
│   │   │   ├── HomePage.js               # Scheduler architecture overview
│   │   │   ├── TestRunnerPage.js         # MPTCP benchmark + live chart
│   │   │   ├── MpquicTestRunnerPage.js   # MPQUIC benchmark + live chart
│   │   │   ├── SchedulerDashboardPage.jsx # Results comparison dashboard
│   │   │   └── *.css
│   │   ├── utils/
│   │   │   └── testResults.js            # localStorage result store
│   │   ├── App.js
│   │   └── index.js
│   └── package.json
│
├── start.sh                # Linux: launches backend + frontend together
├── setup_routing.sh        # Linux: configures per-interface policy routing for mp-quic
└── package.json
```

---

## Prerequisites

### On the Linux VM (backend + full functionality)

| Requirement | Purpose | Install |
|-------------|---------|---------|
| Python 3.7+ | Backend server | Pre-installed on Ubuntu |
| MPTCP-capable kernel | Scheduler sysctl + subflow monitoring | Ubuntu 22.04+ has it built in |
| `iperf3` | MPTCP throughput testing | `sudo apt install iperf3` |
| `mptcpize` | Wrap iperf3 in MPTCP | `sudo apt install mptcpize` |
| `iproute2` (`ip`, `ss`) | Interface + RTT discovery | Pre-installed on Ubuntu |
| Go 1.20 | Build and run mp-quic | See installation steps below |
| mp-quic repository | MPQUIC multipath stack | `git clone https://github.com/qdeconinck/mp-quic.git ~/mp-quic` |
| Node.js 16+ and npm | Frontend dev server | `sudo apt install nodejs npm` (or via nvm) |

### On Windows (frontend / demo mode only)

| Requirement | Install |
|-------------|---------|
| Node.js 16+ | [nodejs.org](https://nodejs.org) |
| npm | Bundled with Node.js |

---

## Installation

### 1. Clone the repository

```bash
git clone <repo-url>
cd Multi-RAT-Web-Application
```

### 2. Install frontend dependencies

```bash
cd frontend
npm install
cd ..
```

### 3. Set up mp-quic (Linux only)

```bash
# Install Go 1.20
wget https://go.dev/dl/go1.20.14.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.20.14.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
source ~/.profile
go version  # should print go1.20.14

# Clone and build mp-quic
git clone https://github.com/qdeconinck/mp-quic.git ~/mp-quic
cd ~/mp-quic
go mod init github.com/lucas-clemente/quic-go
# Populate go.mod with pinned dependencies (see backend/README.md for the full go.mod)
go mod tidy
go build ./...
```

### 4. Configure policy routing for mp-quic (Linux only, run once per boot)

```bash
bash setup_routing.sh
```

This discovers every active interface with a global IPv4 address and installs a dedicated routing table and `ip rule` for each, so mp-quic can bind and route traffic from multiple interfaces simultaneously. `start.sh` runs this automatically on every launch.

### 5. Install iperf3 and mptcpize (Linux only)

```bash
sudo apt update
sudo apt install -y iperf3 mptcpize
```

---

## Running the Application

### Linux (Ubuntu VM — full mode)

```bash
./start.sh
```

This script:
1. Runs `setup_routing.sh` to ensure mp-quic policy routing is up to date
2. Kills any leftover backend process on port 5000
3. Starts `python3 backend/app.py` in the background
4. Starts the React dev server (`npm --prefix frontend start`) in the foreground
5. Shuts the backend down automatically when you press Ctrl+C

The dashboard opens at **http://localhost:3000**.

To run backend and frontend separately:

```bash
# Terminal 1 — backend
python3 backend/app.py

# Terminal 2 — frontend
cd frontend && npm start
```

### Windows (frontend only / demo mode)

The bash scripts do not run on Windows CMD. Run each part manually:

```cmd
:: Terminal 1 — frontend
cd frontend
npm install
npm start
```

If the backend is not reachable, the app starts in **Demo mode** automatically — all pages work with simulated data. See [Demo Mode](#demo-mode) for details.

> **Note:** The MPTCP kernel interfaces (`/proc/sys/net/mptcp/...`) and Linux tools (`iperf3`, `mptcpize`, `ss`, `ip`) are not available on Windows. Live scheduler switching and real throughput data require the Linux VM backend.

---

## Backend API Reference

The backend listens on `http://0.0.0.0:5000`.

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Liveness probe — returns `{"status": "ok"}` |
| `GET` | `/api/schedulers` | Kernel-supported MPTCP schedulers + active one |
| `GET` | `/api/scheduler/current` | Currently active MPTCP scheduler |
| `POST` | `/api/scheduler` | Set the active MPTCP scheduler via `sudo sysctl -w` |
| `POST` | `/api/iperf/start` | Start an MPTCP iperf3 run |
| `GET` | `/api/network/throughput` | Live sample: overall + per-subflow Mbps and RTT + `finished` flag |
| `GET` | `/api/iperf/result` | Final iperf3 summary of the last run |
| `GET` | `/api/mpquic/schedulers` | mp-quic path-selection strategies from `scheduler.go` + current |
| `POST` | `/api/mpquic/scheduler` | Switch mp-quic strategy (rewrites `scheduler.go` + `go build ./...`) |
| `POST` | `/api/mpquic/iperf/start` | Start a multipath mp-quic run |

### Request bodies

**POST /api/scheduler**
```json
{ "scheduler": "lrtt" }
```

**POST /api/iperf/start** and **POST /api/mpquic/iperf/start**
```json
{ "server_ip": "192.168.1.100", "server_port": 5201, "duration": 60 }
```

**POST /api/mpquic/scheduler**
```json
{ "scheduler": "BWA" }
```

### Security

- MPTCP scheduler names are validated against the kernel's own `available_schedulers` list before reaching the command line.
- MPQUIC scheduler names are validated against the `selectPath<Name>` methods parsed from `scheduler.go`.
- All subprocess calls use the argument-list form — `shell=True` is never used.
- `server_ip` and `server_port` are validated before any subprocess is launched.

---

## Dashboard Pages

### Home
Describes every scheduler grouped by protocol (MPTCP / MPQUIC). Novel schedulers are highlighted with a badge. Each card shows the scheduler's tag, a plain-English description, and its scoring formula.

### MPTCP Benchmark
- Select a scheduler from the kernel's live list (or the fallback list in demo mode)
- Enter the iperf3 server IP, port, and test duration (any positive integer in seconds)
- Hit **Start** to run `mptcpize run iperf3` and watch overall throughput update every second
- Results are saved automatically to the Scheduler Dashboard

### MPQUIC Benchmark
- Select an mp-quic path-selection strategy
- The backend rewrites `scheduler.go` and runs `go build ./...` to activate it (takes a few seconds)
- Enter the mp-quic server address, port, and duration
- Hit **Start** to run the mp-quic iperf client and watch per-path throughput live

### Scheduler Dashboard
- Compares all saved runs side by side in the **All Runs** table
- Click any row to load its throughput-over-time chart and per-subflow RTT breakdown
- Check individual rows and hit **Clear selected** to remove only those results — other runs are preserved

---

## Sudo Configuration for Scheduler Switching

`POST /api/scheduler` calls `sudo sysctl -w net.mptcp.scheduler=<name>`. To allow this without a password prompt, add a scoped sudoers rule:

```bash
sudo visudo -f /etc/sudoers.d/mptcp-scheduler
```

Add (replace `<username>` with the account running the backend):

```
<username> ALL=(root) NOPASSWD: /usr/sbin/sysctl -w net.mptcp.scheduler=*
```

Then:

```bash
sudo chmod 440 /etc/sudoers.d/mptcp-scheduler

# Verify — should not prompt for a password:
sudo -n /usr/sbin/sysctl -w net.mptcp.scheduler=lrtt
```

---

## Demo Mode

When the backend is unreachable (e.g. running the frontend on Windows without the VM), both benchmark pages detect this on startup and switch to **Demo mode** automatically:

- A simulated throughput curve is generated every second
- Two fake subflows (`link-a`, `link-b`) appear with fixed demo RTT values
- A fake iperf3 summary is produced at the end of the run
- All demo results are saved to the Scheduler Dashboard and labelled **Demo data**

No configuration is needed — demo mode activates automatically and the badge in the top bar shows the current state.

---

## Development Notes

- **Backend URL:** Both benchmark pages hardcode `BACKEND_URL = 'http://localhost:5000'`. If the backend runs on a separate VM, update this constant in `frontend/src/pages/TestRunnerPage.js` and `MpquicTestRunnerPage.js` to point at the VM's IP address (e.g. `http://192.168.147.130:5000`).
- **mp-quic directory:** The backend looks for mp-quic at `~/mp-quic` by default. Override with the `MPQUIC_DIR` environment variable.
- **MPTCP kernel:** Ubuntu 22.04 LTS and later ship with an MPTCP-capable kernel. Older releases require a kernel from [mptcp.dev](https://www.mptcp.dev/).
- **Port 5000 conflict:** On some systems port 5000 may already be in use. Change the `PORT` constant in `backend/app.py` and update `BACKEND_URL` in both frontend pages to match.
- **Result storage:** Test results are stored in `localStorage` in the browser. Clearing browser data will also clear the Scheduler Dashboard. Results do not sync across different browsers or machines.
