import React, { useState, useRef, useEffect } from 'react';
import {
    AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer
} from 'recharts';
import { saveTestResult, computeStats } from '../utils/testResults';
import './TestRunnerPage.css';
// ---------------------------------------------------------------------------
// Test Runner page
//
// Flow: choose scheduler -> choose duration -> Start.
// On Start the backend (on the VM) sets net.mptcp.scheduler to the chosen
// scheduler, runs iperf3 for the chosen duration, and streams back:
//   - overall network throughput over time (from /proc/net/dev)
//   - the final iperf3 summary (from iperf3 --json)
//
// Right now BACKEND_URL points at a placeholder. While it is unreachable the
// page runs in DEMO mode with fake data so you can see it work on Windows.
// When your Flask backend is running on the VM, set BACKEND_URL to it and the
// page uses the real thing automatically.
// ---------------------------------------------------------------------------

// The backend runs on the same host as the browser (start.sh launches it on
// :5000). Point at localhost so it works out of the box; change this only if
// you run the backend on a separate VM.
const BACKEND_URL = 'http://localhost:5000';

// Fallback list used only when the backend / VM kernel is unreachable (e.g. the
// demo on Windows). When the backend is up, the list comes live from
// `cat /proc/sys/net/mptcp/available_schedulers`.
const FALLBACK_SCHEDULERS = [
    'default', 'rrpacket', 'lrtt', 'redundant', 'blest', 'ecf', 'hybrid', 'novelcwl2',
];

// Friendly labels for known kernel scheduler names; anything unknown shows as-is.
const SCHED_LABELS = {
    default: 'Default',
    rrpacket: 'Round Robin',
    roundrobin: 'Round Robin',
    lrtt: 'LRTT',
    redundant: 'Redundant',
    blest: 'BLEST',
    ecf: 'ECF',
    hybrid: 'Hybrid',
    novelcwl2: 'CWL (novel)',
    cwl: 'CWL (novel)',
};
const prettyScheduler = (name) => SCHED_LABELS[name] || name;

// Basic IPv4 / hostname validation for the iperf3 target
const isValidHost = (h) => {
    if (!h) return false;
    const ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
    const m = h.match(ipv4);
    if (m) return m.slice(1).every(o => Number(o) >= 0 && Number(o) <= 255);
    // otherwise accept a hostname (letters, digits, dots, hyphens)
    return /^[a-zA-Z0-9.-]+$/.test(h);
};
const isValidPort = (p) => Number.isInteger(Number(p)) && Number(p) >= 1 && Number(p) <= 65535;
const isValidDuration = (d) => Number.isInteger(Number(d)) && Number(d) >= 1;

const TestRunnerPage = () => {
    const [schedulers, setSchedulers] = useState(FALLBACK_SCHEDULERS); // kernel names
    const [scheduler, setScheduler] = useState(FALLBACK_SCHEDULERS[0]);
    const [schedStatus, setSchedStatus] = useState(null); // { kind, text }
    const [duration, setDuration] = useState('30');
    const [serverIp, setServerIp] = useState('68.183.225.112'); // iperf3 target host
    const [serverPort, setServerPort] = useState(5201);          // iperf3 default port
    const [running, setRunning] = useState(false);
    const [series, setSeries] = useState([]);          // [{t, mbps}]
    const [summary, setSummary] = useState(null);       // iperf3 summary
    const [log, setLog] = useState([]);                 // status lines
    const [demo, setDemo] = useState(true);
    const timerRef = useRef(null);
    const tickRef = useRef(0);
    const seriesRef = useRef([]);       // latest series, kept in lockstep for persist
    const ifacesRef = useRef([]);          // interface names discovered from the backend
    const subflowRttRef = useRef({});      // per-interface RTT (ms) — demo fallback
    const subflowRttSamplesRef = useRef({}); // per-interface RTT samples, for the run average

    const addLog = (line) =>
        setLog(prev => [...prev, `[${new Date().toLocaleTimeString()}] ${line}`]);

    const schedulerLabel = () => prettyScheduler(scheduler);

    // Apply the chosen scheduler on the kernel (sudo sysctl -w) via the backend.
    // In demo mode we can only change the local selection.
    const onSelectScheduler = async (name) => {
        setScheduler(name);
        if (demo) {
            setSchedStatus({ kind: 'info', text: 'Demo mode — kernel scheduler not changed.' });
            return;
        }
        setSchedStatus({ kind: 'info', text: `Setting kernel scheduler to ${prettyScheduler(name)}…` });
        try {
            const r = await fetch(`${BACKEND_URL}/api/scheduler`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ scheduler: name }),
            });
            const d = await r.json().catch(() => ({}));
            if (r.ok && d.ok !== false) {
                setSchedStatus({ kind: 'ok', text: `Active kernel scheduler: ${prettyScheduler(d.current || name)}` });
                addLog(`Kernel scheduler set to ${name}`);
            } else {
                setSchedStatus({ kind: 'err', text: `Failed to set scheduler: ${d.error || `HTTP ${r.status}`}` });
            }
        } catch (e) {
            setSchedStatus({ kind: 'err', text: 'Could not reach backend to set scheduler.' });
        }
    };

    // Persist a finished run so the Scheduler Dashboard can display it.
    const persistResult = (summaryObj) => {
        const pts = seriesRef.current;
        // Average each subflow's RTT over the whole run. Falls back to whatever
        // is in subflowRttRef (e.g. the fixed demo values) when no live samples
        // were collected for an interface.
        const rtt = { ...subflowRttRef.current };
        Object.entries(subflowRttSamplesRef.current).forEach(([iface, vals]) => {
            if (vals.length) {
                rtt[iface] = Number((vals.reduce((a, b) => a + b, 0) / vals.length).toFixed(2));
            }
        });
        saveTestResult({
            label: schedulerLabel(),
            scheduler,
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

    // ---- DEMO ticker: fabricate a throughput curve while running ----
    const startDemo = () => {
        tickRef.current = 0;
        setSeries([]);
        // Two fake subflows so the dashboard's per-subflow breakdown is
        // populated even without the VM backend.
        const demoIfaces = ['link-a', 'link-b'];
        ifacesRef.current = demoIfaces;
        subflowRttRef.current = { 'link-a': 24.5, 'link-b': 38.2 };
        timerRef.current = setInterval(() => {
            tickRef.current += 1;
            const base = 18 + Math.sin(tickRef.current / 3) * 3;
            const noise = (Math.random() - 0.5) * 2;
            const total = Math.max(0, Number((base + noise).toFixed(2)));
            // Split the total across the two demo subflows (~60/40).
            const a = Number((total * 0.6).toFixed(2));
            const b = Number((total - a).toFixed(2));
            setSeries(prev => {
                const point = { t: tickRef.current, mbps: total, 'link-a': a, 'link-b': b };
                const next = [...prev, point];
                seriesRef.current = next;
                return next;
            });
            if (tickRef.current >= Number(duration)) {
                stopRun(true);
            }
        }, 1000);
    };

    // ---- REAL: call the VM backend ----
    const startReal = async () => {
        addLog(`Setting scheduler to ${scheduler} on the VM`);
        await fetch(`${BACKEND_URL}/api/scheduler`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ scheduler }),
        });
        addLog(`Starting iperf3 -> ${serverIp}:${serverPort} for ${duration}s`);
        await fetch(`${BACKEND_URL}/api/iperf/start`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ duration: Number(duration), server_ip: serverIp, server_port: Number(serverPort) }),
        });
        // poll live counters
        timerRef.current = setInterval(async () => {
            try {
                const r = await fetch(`${BACKEND_URL}/api/network/throughput`);
                const d = await r.json();
                const subflows = d.subflows || {};

                // Remember the interfaces, and collect every RTT sample so the
                // Scheduler Dashboard can show a run-average per subflow.
                if (Array.isArray(d.ifaces) && d.ifaces.length) ifacesRef.current = d.ifaces;
                Object.entries(subflows).forEach(([iface, s]) => {
                    if (s && s.rtt != null) {
                        const arr = subflowRttSamplesRef.current[iface]
                            || (subflowRttSamplesRef.current[iface] = []);
                        arr.push(s.rtt);
                    }
                });

                setSeries(prev => {
                    // Each point carries the total plus one key per subflow, which
                    // the dashboard's chart and per-subflow cards both read.
                    const point = { t: prev.length + 1, mbps: d.total_mbps };
                    Object.entries(subflows).forEach(([iface, s]) => {
                        point[iface] = s ? s.mbps : 0;
                    });
                    const next = [...prev, point];
                    seriesRef.current = next;   // keep ref current for persistResult
                    return next;
                });
                if (d.finished) {
                    const s = await fetch(`${BACKEND_URL}/api/iperf/result`);
                    const result = await s.json();
                    setSummary(result);
                    persistResult(result);
                    stopRun(false);
                }
            } catch (e) {
                addLog('Lost contact with backend');
            }
        }, 1000);
    };

    const startRun = async () => {
        // Validate the iperf3 target before doing anything
        if (!isValidHost(serverIp)) {
            addLog(`Invalid server IP / host: "${serverIp}"`);
            return;
        }
        if (!isValidPort(serverPort)) {
            addLog(`Invalid port: "${serverPort}" (must be 1–65535)`);
            return;
        }

        setRunning(true);
        setSummary(null);
        setSeries([]);
        setLog([]);
        seriesRef.current = [];
        ifacesRef.current = [];
        subflowRttRef.current = {};
        subflowRttSamplesRef.current = {};
        addLog(`Selected scheduler: ${schedulerLabel()} (${scheduler})`);
        addLog(`Target: ${serverIp}:${serverPort}`);
        addLog(`Duration: ${duration}s`);

        // Probe backend; if not reachable, use demo mode
        let backendUp = false;
        try {
            const ping = await fetch(`${BACKEND_URL}/health`, { signal: AbortSignal.timeout(1500) });
            backendUp = ping.ok;
        } catch (e) {
            backendUp = false;
        }

        if (backendUp) {
            setDemo(false);
            addLog('Backend reachable. Running on the VM.');
            startReal();
        } else {
            setDemo(true);
            addLog('Backend not reachable. Running in DEMO mode with fake data.');
            startDemo();
        }
    };

    const stopRun = (finishedNaturally) => {
        clearInterval(timerRef.current);
        timerRef.current = null;
        setRunning(false);
        if (demo) {
            addLog(finishedNaturally ? 'Test finished (demo).' : 'Test stopped (demo).');
            // fake summary
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
            addLog('Test finished.');
        }
    };

    // keep a ref to series for the stop handler
    useEffect(() => { seriesRef.current = series; }, [series]);

    // On load, ask the backend for the schedulers the kernel actually supports
    // (cat /proc/sys/net/mptcp/available_schedulers). If it answers we run in
    // Live mode with the real list; otherwise we fall back to the built-in list
    // and Demo mode so the page still works without the VM.
    useEffect(() => {
        (async () => {
            try {
                const r = await fetch(`${BACKEND_URL}/api/schedulers`, { signal: AbortSignal.timeout(1500) });
                if (!r.ok) throw new Error(`HTTP ${r.status}`);
                const data = await r.json();
                const names = Array.isArray(data) ? data : (data.schedulers || []);
                if (names.length === 0) throw new Error('empty scheduler list');

                setSchedulers(names);
                const current = data.current && names.includes(data.current) ? data.current : names[0];
                setScheduler(current);
                setDemo(false);
                setSchedStatus({
                    kind: 'ok',
                    text: `Loaded ${names.length} schedulers from kernel. Active: ${prettyScheduler(current)}`,
                });
            } catch (e) {
                setSchedulers(FALLBACK_SCHEDULERS);
                setScheduler(FALLBACK_SCHEDULERS[0]);
                setDemo(true);
                setSchedStatus({
                    kind: 'info',
                    text: 'Backend offline — showing built-in scheduler list (demo).',
                });
            }
        })();
    }, []);

    const yMax = 30; // fixed axis so the curve is comparable between runs

    return (
        <div className="tr-page">
            <h1 className="tr-title">MPTCP Benchmark</h1>
            <p className="tr-subtitle">
                Choose a scheduler and duration, then run iperf3. Overall network throughput is shown here.
            </p>

            {/* Controls */}
            <div className="tr-controls">
                <div>
                    <label className="tr-field-label">SCHEDULER</label>
                    <select
                        className="tr-select"
                        value={scheduler}
                        disabled={running}
                        onChange={(e) => onSelectScheduler(e.target.value)}
                    >
                        {schedulers.map(name => (
                            <option key={name} value={name}>{prettyScheduler(name)}</option>
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
                        placeholder="5201"
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
                        disabled={!isValidHost(serverIp) || !isValidPort(serverPort) || !isValidDuration(duration)}
                    >▶ Start</button>
                ) : (
                    <button className="tr-btn tr-btn--stop" onClick={() => stopRun(false)}>■ Stop</button>
                )}

                <div className={`tr-badge ${demo ? 'tr-badge--down' : 'tr-badge--up'}`}>
                    {running ? (demo ? 'RUNNING (demo data)' : 'RUNNING (live)') : (demo ? 'Demo mode' : 'Live mode')}
                </div>
            </div>

            {/* Scheduler apply status */}
            {schedStatus && (
                <div className={`tr-sched-status tr-sched-status--${schedStatus.kind}`}>
                    {schedStatus.text}
                </div>
            )}

            {/* Overall network chart */}
            <div className="tr-card">
                <h3 className="tr-card-title">Overall Network Throughput</h3>
                <ResponsiveContainer width="100%" height={280}>
                    <AreaChart data={series}>
                        <defs>
                            <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
                                <stop offset="0%" stopColor="#0D9488" stopOpacity={0.5} />
                                <stop offset="100%" stopColor="#0D9488" stopOpacity={0.05} />
                            </linearGradient>
                        </defs>
                        <CartesianGrid strokeDasharray="3 3" stroke="#E2E8F0" />
                        <XAxis dataKey="t" stroke="#94A3B8" label={{ value: 'seconds', position: 'insideBottom', offset: -3 }} />
                        <YAxis domain={[0, yMax]} stroke="#94A3B8" label={{ value: 'Mbps', angle: -90, position: 'insideLeft' }} />
                        <Tooltip />
                        <Legend />
                        <Area type="monotone" dataKey="mbps" stroke="#0D9488" strokeWidth={2} fill="url(#g)" name="Total throughput" isAnimationActive={false} />
                    </AreaChart>
                </ResponsiveContainer>
            </div>

            {/* Summary + log */}
            <div className="tr-bottom-grid">
                <div className="tr-result">
                    <h3 className="tr-card-title">iperf3 Result</h3>
                    {summary ? (
                        <div className="tr-result-grid">
                            <Stat label="Scheduler" value={schedulerLabel()} />
                            <Stat label="Target" value={summary.target || `${serverIp}:${serverPort}`} />
                            <Stat label="Duration" value={`${summary.duration}s`} />
                            <Stat label="Throughput" value={`${summary.throughput_mbps} Mbps`} />
                            <Stat label="Retransmits" value={summary.retransmits} />
                        </div>
                    ) : (
                        <p className="tr-empty">No result yet. Run a test to see the iperf3 summary.</p>
                    )}
                    {summary?.demo && (
                        <p className="tr-demo-note">Demo values. Connect the VM backend for real numbers.</p>
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

export default TestRunnerPage;
