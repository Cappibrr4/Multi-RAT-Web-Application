import React, { useState, useRef, useEffect } from 'react';
import {
    AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer
} from 'recharts';
import { saveTestResult, computeStats } from '../utils/testResults';
import './TestRunnerPage.css';   // reuse the MPTCP runner styling

// ---------------------------------------------------------------------------
// MPQUIC Test Runner page
//
// The mp-quic library selects its path scheduler at COMPILE time (by editing
// scheduler.go and rebuilding), not via a runtime sysctl like MPTCP. So this
// page lists the scheduler strategies that exist in mp-quic/scheduler.go —
// fetched live from the backend, which parses that file — and marks the one the
// selectPath() dispatcher currently calls as active.
//
// Running an actual mp-quic transfer per scheduler requires the mp-quic client
// binary (and a rebuild to switch schedulers), which isn't wired to the backend
// yet, so Start here produces a demo throughput curve. The scheduler list is
// the real, dynamic part — identical in spirit to the MPTCP side.
// ---------------------------------------------------------------------------

const BACKEND_URL = 'http://localhost:5000';

// Fallback list used only when the backend / scheduler.go is unreachable. These
// are the selectPath<Name> strategies in mp-quic/scheduler.go.
const FALLBACK_SCHEDULERS = ['BWA', 'RoundRobin', 'LowLatency', 'BWLS'];

// Friendly labels for the mp-quic strategy names; anything unknown shows as-is.
const SCHED_LABELS = {
    BWA: 'BWA (novel)',
    RoundRobin: 'Round Robin',
    LowLatency: 'Low Latency (LRTT)',
    LRTT: 'Low Latency (LRTT)',
    BWLS: 'BWLS (novel)',
};
const prettyScheduler = (name) => SCHED_LABELS[name] || name;

const isValidHost = (h) => {
    if (!h) return false;
    const ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
    const m = h.match(ipv4);
    if (m) return m.slice(1).every(o => Number(o) >= 0 && Number(o) <= 255);
    return /^[a-zA-Z0-9.-]+$/.test(h);
};
const isValidPort = (p) => Number.isInteger(Number(p)) && Number(p) >= 1 && Number(p) <= 65535;
const isValidDuration = (d) => Number.isInteger(Number(d)) && Number(d) >= 1;

const MpquicTestRunnerPage = () => {
    const [schedulers, setSchedulers] = useState(FALLBACK_SCHEDULERS);
    const [scheduler, setScheduler] = useState(FALLBACK_SCHEDULERS[0]);
    const [current, setCurrent] = useState(null);   // the compiled-in active strategy
    const [live, setLive] = useState(false);        // scheduler list came from the backend
    const [building, setBuilding] = useState(false); // editing scheduler.go + go build
    const [schedStatus, setSchedStatus] = useState(null);
    const [duration, setDuration] = useState('30');
    const [serverIp, setServerIp] = useState('68.183.225.112');
    const [serverPort, setServerPort] = useState(6121);   // common quic-go port
    const [running, setRunning] = useState(false);
    const [demo, setDemo] = useState(true);         // fell back to fake data (backend down)
    const [series, setSeries] = useState([]);
    const [summary, setSummary] = useState(null);
    const [log, setLog] = useState([]);

    const timerRef = useRef(null);
    const tickRef = useRef(0);
    const seriesRef = useRef([]);
    const ifacesRef = useRef([]);
    const subflowRttRef = useRef({});
    const subflowRttSamplesRef = useRef({});
    const demoRef = useRef(true);   // current run's mode, read by stopRun (state lags)

    const addLog = (line) =>
        setLog(prev => [...prev, `[${new Date().toLocaleTimeString()}] ${line}`]);

    const schedulerLabel = () => prettyScheduler(scheduler);

    useEffect(() => { seriesRef.current = series; }, [series]);

    // Load the scheduler strategies from mp-quic/scheduler.go via the backend.
    useEffect(() => {
        (async () => {
            try {
                const r = await fetch(`${BACKEND_URL}/api/mpquic/schedulers`, { signal: AbortSignal.timeout(1500) });
                if (!r.ok) throw new Error(`HTTP ${r.status}`);
                const data = await r.json();
                const names = Array.isArray(data) ? data : (data.schedulers || []);
                if (names.length === 0) throw new Error('empty scheduler list');

                setSchedulers(names);
                setCurrent(data.current || null);
                setScheduler(data.current && names.includes(data.current) ? data.current : names[0]);
                setLive(true);
                setSchedStatus({
                    kind: 'ok',
                    text: `Loaded ${names.length} strategies from scheduler.go. Compiled-in: ${data.current ? prettyScheduler(data.current) : 'unknown'}`,
                });
            } catch (e) {
                setSchedulers(FALLBACK_SCHEDULERS);
                setScheduler(FALLBACK_SCHEDULERS[0]);
                setLive(false);
                setSchedStatus({
                    kind: 'info',
                    text: 'Backend / scheduler.go offline — showing built-in mp-quic strategy list.',
                });
            }
        })();
    }, []);

    // Selecting a strategy edits scheduler.go on the backend (comment/uncomment
    // the selectPath() return line) and runs `go build ./...` to recompile
    // mp-quic with that scheduler. The build can take a while, so controls are
    // locked and the status line shows progress.
    const onSelectScheduler = async (name) => {
        setScheduler(name);
        if (!live) {
            setSchedStatus({ kind: 'info', text: 'Backend offline — scheduler.go not edited. Start the backend to switch schedulers.' });
            return;
        }
        setBuilding(true);
        setSchedStatus({ kind: 'info', text: `Editing scheduler.go and running go build for ${prettyScheduler(name)}… this can take a while.` });
        addLog(`Switching mp-quic scheduler to ${name} (editing scheduler.go + go build)…`);
        try {
            const r = await fetch(`${BACKEND_URL}/api/mpquic/scheduler`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ scheduler: name }),
            });
            const d = await r.json().catch(() => ({}));
            if (r.ok && d.ok !== false) {
                setCurrent(d.current || name);
                setSchedStatus({ kind: 'ok', text: `Built. Compiled-in scheduler is now ${prettyScheduler(d.current || name)}.` });
                addLog(`Build succeeded — mp-quic now uses ${prettyScheduler(d.current || name)}.`);
            } else {
                const msg = d.error || `HTTP ${r.status}`;
                setSchedStatus({ kind: 'err', text: `Build failed: ${msg}` });
                addLog(`Build failed: ${msg}`);
            }
        } catch (e) {
            setSchedStatus({ kind: 'err', text: 'Could not reach backend to change scheduler.' });
            addLog('Could not reach backend to change scheduler.');
        } finally {
            setBuilding(false);
        }
    };

    const persistResult = (summaryObj) => {
        const pts = seriesRef.current;
        // Average each path's RTT over the run (falls back to subflowRttRef, e.g.
        // the demo values). mp-quic is UDP so live RTT is usually absent.
        const rtt = { ...subflowRttRef.current };
        Object.entries(subflowRttSamplesRef.current).forEach(([iface, vals]) => {
            if (vals.length) {
                rtt[iface] = Number((vals.reduce((a, b) => a + b, 0) / vals.length).toFixed(2));
            }
        });
        saveTestResult({
            label: `${schedulerLabel()} (QUIC)`,   // keep MPQUIC runs distinct from MPTCP
            scheduler,
            protocol: 'mpquic',
            target: `${serverIp}:${serverPort}`,
            duration: Number(duration),
            demo: !!summaryObj.demo,
            summary: summaryObj,
            series: pts,
            stats: computeStats(pts),
            ifaces: ifacesRef.current,
            subflowRtt: rtt,
            timestamp: Date.now(),
        });
        addLog('Result saved to Scheduler Dashboard.');
    };

    // ---- REAL: run mp-quic on the backend and poll per-path throughput ----
    const startReal = async () => {
        addLog(`Starting mp-quic multipath -> ${serverIp}:${serverPort} for ${duration}s`);
        addLog('(go run compiles first; traffic starts a few seconds in.)');
        const r0 = await fetch(`${BACKEND_URL}/api/mpquic/iperf/start`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ duration: Number(duration), server_ip: serverIp, server_port: Number(serverPort) }),
        });
        const d0 = await r0.json().catch(() => ({}));
        if (!r0.ok || d0.ok === false) {
            addLog(`Backend refused the run: ${d0.error || `HTTP ${r0.status}`}`);
            stopRun(false);
            return;
        }
        timerRef.current = setInterval(async () => {
            try {
                const r = await fetch(`${BACKEND_URL}/api/network/throughput`);
                const d = await r.json();
                const subflows = d.subflows || {};

                if (Array.isArray(d.ifaces) && d.ifaces.length) ifacesRef.current = d.ifaces;
                Object.entries(subflows).forEach(([iface, s]) => {
                    if (s && s.rtt != null) {
                        const arr = subflowRttSamplesRef.current[iface]
                            || (subflowRttSamplesRef.current[iface] = []);
                        arr.push(s.rtt);
                    }
                });

                setSeries(prev => {
                    const point = { t: prev.length + 1, mbps: d.total_mbps };
                    Object.entries(subflows).forEach(([iface, s]) => {
                        point[iface] = s ? s.mbps : 0;
                    });
                    const next = [...prev, point];
                    seriesRef.current = next;
                    return next;
                });

                if (d.finished) {
                    const s = await fetch(`${BACKEND_URL}/api/iperf/result`);
                    const result = await s.json();
                    setSummary(result);
                    if (result.error) addLog(`mp-quic error: ${result.error}`);
                    persistResult(result);
                    stopRun(false);
                }
            } catch (e) {
                addLog('Lost contact with backend');
            }
        }, 1000);
    };

    // ---- DEMO: fabricate a curve split across two paths (backend offline) ----
    const startDemo = () => {
        tickRef.current = 0;
        setSeries([]);
        const demoIfaces = ['path-0', 'path-1'];
        ifacesRef.current = demoIfaces;
        subflowRttRef.current = { 'path-0': 22.0, 'path-1': 41.5 };
        timerRef.current = setInterval(() => {
            tickRef.current += 1;
            const base = 20 + Math.sin(tickRef.current / 3) * 4;
            const noise = (Math.random() - 0.5) * 2;
            const total = Math.max(0, Number((base + noise).toFixed(2)));
            const a = Number((total * 0.55).toFixed(2));
            const b = Number((total - a).toFixed(2));
            setSeries(prev => {
                const point = { t: tickRef.current, mbps: total, 'path-0': a, 'path-1': b };
                const next = [...prev, point];
                seriesRef.current = next;
                return next;
            });
            if (tickRef.current >= Number(duration)) stopRun(true);
        }, 1000);
    };

    const startRun = async () => {
        if (!isValidHost(serverIp)) { addLog(`Invalid server IP / host: "${serverIp}"`); return; }
        if (!isValidPort(serverPort)) { addLog(`Invalid port: "${serverPort}" (must be 1–65535)`); return; }

        setRunning(true);
        setSummary(null);
        setSeries([]);
        setLog([]);
        seriesRef.current = [];
        ifacesRef.current = [];
        subflowRttRef.current = {};
        subflowRttSamplesRef.current = {};
        addLog(`Selected mp-quic strategy: ${schedulerLabel()} (${scheduler})`);
        if (current && scheduler !== current) {
            addLog(`Note: compiled-in strategy is ${prettyScheduler(current)}. mp-quic selects the scheduler at build time — rebuild scheduler.go to change it live.`);
        }
        addLog(`Target: ${serverIp}:${serverPort}`);
        addLog(`Duration: ${duration}s`);

        let backendUp = false;
        try {
            const ping = await fetch(`${BACKEND_URL}/health`, { signal: AbortSignal.timeout(1500) });
            backendUp = ping.ok;
        } catch (e) {
            backendUp = false;
        }

        if (backendUp) {
            setDemo(false);
            demoRef.current = false;
            addLog('Backend reachable. Running mp-quic on the host.');
            startReal();
        } else {
            setDemo(true);
            demoRef.current = true;
            addLog('Backend not reachable. Running in DEMO mode with fake data.');
            startDemo();
        }
    };

    const stopRun = (finishedNaturally) => {
        clearInterval(timerRef.current);
        timerRef.current = null;
        setRunning(false);
        if (demoRef.current) {
            addLog(finishedNaturally ? 'Test finished (demo).' : 'Test stopped (demo).');
            const vals = seriesRef.current.map(p => p.mbps);
            const avg = vals.length ? (vals.reduce((a, b) => a + b, 0) / vals.length) : 0;
            const summaryObj = {
                scheduler,
                duration: Number(duration),
                target: `${serverIp}:${serverPort}`,
                throughput_mbps: Number(avg.toFixed(2)),
                retransmits: Math.floor(Math.random() * 40),
                demo: true,
            };
            setSummary(summaryObj);
            if (vals.length) persistResult(summaryObj);
        } else {
            addLog(finishedNaturally ? 'Test finished.' : 'Test stopped.');
        }
    };

    const yMax = 32;

    return (
        <div className="tr-page">
            <h1 className="tr-title">MPQUIC Benchmark</h1>
            <p className="tr-subtitle">
                Strategies are read from <code>scheduler.go</code>; selecting one recompiles mp-quic
                (<code>go build ./...</code>). Start runs <code>go run example/iperf_client/main.go … -multipath</code>
                on the host and charts overall + per-path throughput.
            </p>

            <div className="tr-controls">
                <div>
                    <label className="tr-field-label">SCHEDULER</label>
                    <select
                        className="tr-select"
                        value={scheduler}
                        disabled={running || building}
                        onChange={(e) => onSelectScheduler(e.target.value)}
                    >
                        {schedulers.map(name => (
                            <option key={name} value={name}>
                                {prettyScheduler(name)}{name === current ? ' • compiled-in' : ''}
                            </option>
                        ))}
                    </select>
                </div>

                <div>
                    <label className="tr-field-label">SERVER IP / HOST</label>
                    <input
                        className={`tr-input ${serverIp && !isValidHost(serverIp) ? 'tr-input--error' : ''}`}
                        type="text"
                        value={serverIp}
                        disabled={running}
                        placeholder="e.g. 192.168.147.130"
                        onChange={(e) => setServerIp(e.target.value.trim())}
                    />
                </div>

                <div>
                    <label className="tr-field-label">PORT</label>
                    <input
                        className={`tr-input tr-input--port ${serverPort && !isValidPort(serverPort) ? 'tr-input--error' : ''}`}
                        type="number"
                        min="1"
                        max="65535"
                        value={serverPort}
                        disabled={running}
                        placeholder="6121"
                        onChange={(e) => setServerPort(e.target.value)}
                    />
                </div>

                <div>
                    <label className="tr-field-label">DURATION (seconds)</label>
                    <input
                        className={`tr-input tr-input--port ${duration && !isValidDuration(duration) ? 'tr-input--error' : ''}`}
                        type="text"
                        value={duration}
                        disabled={running}
                        placeholder="e.g. 60"
                        onChange={(e) => setDuration(e.target.value)}
                    />
                </div>

                {!running ? (
                    <button
                        className="tr-btn tr-btn--start"
                        onClick={startRun}
                        disabled={building || !isValidHost(serverIp) || !isValidPort(serverPort) || !isValidDuration(duration)}
                    >▶ Start</button>
                ) : (
                    <button className="tr-btn tr-btn--stop" onClick={() => stopRun(false)}>■ Stop</button>
                )}

                <div className={`tr-badge ${(running && !demo) ? 'tr-badge--up' : 'tr-badge--down'}`}>
                    {building ? 'BUILDING…'
                        : running ? (demo ? 'RUNNING (demo data)' : 'RUNNING (live)')
                        : 'Idle'}
                </div>
            </div>

            {schedStatus && (
                <div className={`tr-sched-status tr-sched-status--${schedStatus.kind}`}>
                    {schedStatus.text}
                </div>
            )}

            <div className="tr-card">
                <h3 className="tr-card-title">Overall Network Throughput</h3>
                <ResponsiveContainer width="100%" height={280}>
                    <AreaChart data={series}>
                        <defs>
                            <linearGradient id="gq" x1="0" y1="0" x2="0" y2="1">
                                <stop offset="0%" stopColor="#7C3AED" stopOpacity={0.5} />
                                <stop offset="100%" stopColor="#7C3AED" stopOpacity={0.05} />
                            </linearGradient>
                        </defs>
                        <CartesianGrid strokeDasharray="3 3" stroke="#E2E8F0" />
                        <XAxis dataKey="t" stroke="#94A3B8" label={{ value: 'seconds', position: 'insideBottom', offset: -3 }} />
                        <YAxis domain={[0, yMax]} stroke="#94A3B8" label={{ value: 'Mbps', angle: -90, position: 'insideLeft' }} />
                        <Tooltip />
                        <Legend />
                        <Area type="monotone" dataKey="mbps" stroke="#7C3AED" strokeWidth={2} fill="url(#gq)" name="Total throughput" isAnimationActive={false} />
                    </AreaChart>
                </ResponsiveContainer>
            </div>

            <div className="tr-bottom-grid">
                <div className="tr-result">
                    <h3 className="tr-card-title">mp-quic Result</h3>
                    {summary ? (
                        <div className="tr-result-grid">
                            <Stat label="Scheduler" value={schedulerLabel()} />
                            <Stat label="Target" value={summary.target || `${serverIp}:${serverPort}`} />
                            <Stat label="Duration" value={`${summary.duration}s`} />
                            <Stat label="Throughput" value={`${summary.throughput_mbps} Mbps`} />
                            <Stat label="Retransmits" value={summary.retransmits} />
                        </div>
                    ) : (
                        <p className="tr-empty">No result yet. Run a test to see the mp-quic summary.</p>
                    )}
                    {summary?.demo && (
                        <p className="tr-demo-note">Demo values. Wire the mp-quic client to the backend for real numbers.</p>
                    )}
                </div>

                <div className="tr-log">
                    <div className="tr-log-title">STATUS LOG</div>
                    {log.length === 0 ? <div className="tr-log-idle">Idle.</div> :
                        log.map((l, i) => <div key={i}>{l}</div>)}
                </div>
            </div>
        </div>
    );
};

const Stat = ({ label, value }) => (
    <div>
        <div className="tr-stat-label">{label}</div>
        <div className="tr-stat-value">{value}</div>
    </div>
);

export default MpquicTestRunnerPage;
