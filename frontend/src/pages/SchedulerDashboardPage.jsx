import React, { useState, useEffect, useMemo } from 'react';
import {
    LineChart, Line, XAxis, YAxis, CartesianGrid,
    Tooltip, Legend, ResponsiveContainer
} from 'recharts';
import { loadTestResults, deleteTestResults } from '../utils/testResults';
import './SchedulerDashboardPage.css';

// Colors assigned to subflows (interfaces) in order.
const SUBFLOW_COLORS = ['#2196F3', '#FF9800', '#4CAF50', '#9C27B0', '#F44336', '#00BCD4', '#795548', '#607D8B'];
const subflowColor = (i) => SUBFLOW_COLORS[i % SUBFLOW_COLORS.length];

// ---------------------------------------------------------------------------
// Scheduler Dashboard
//
// Shows the results produced by the Test Runner page. Nothing here is
// hard-coded: every run the Test Runner finishes is saved to localStorage and
// read back here. Pick a scheduler to see its throughput curve and summary.
// ---------------------------------------------------------------------------

const SchedulerDashboardPage = () => {
    const [results, setResults] = useState({});
    const [selected, setSelected] = useState(null);
    const [checked, setChecked] = useState(new Set());

    // Load saved results on mount, and refresh when another tab writes or when
    // the user returns to this tab after running a test.
    const refresh = () => setResults(loadTestResults());
    useEffect(() => {
        refresh();
        window.addEventListener('storage', refresh);
        window.addEventListener('focus', refresh);
        return () => {
            window.removeEventListener('storage', refresh);
            window.removeEventListener('focus', refresh);
        };
    }, []);

    // Records newest first.
    const records = useMemo(
        () => Object.values(results).sort((a, b) => b.timestamp - a.timestamp),
        [results]
    );

    // Default the selection to the most recent run once results arrive.
    useEffect(() => {
        if (records.length === 0) {
            setSelected(null);
        } else if (!selected || !results[selected]) {
            setSelected(records[0].label);
        }
    }, [records, results, selected]);

    const toggleCheck = (label) => {
        setChecked(prev => {
            const next = new Set(prev);
            next.has(label) ? next.delete(label) : next.add(label);
            return next;
        });
    };

    const toggleAll = () => {
        setChecked(prev =>
            prev.size === records.length
                ? new Set()
                : new Set(records.map(r => r.label))
        );
    };

    const handleClear = () => {
        if (checked.size === 0) return;
        deleteTestResults([...checked]);
        setChecked(new Set());
        refresh();
    };

    // Fixed y-axis maximum across all stored runs (clean multiple of 5) so
    // curves stay comparable. Computed before any early return to keep hook
    // order stable.
    const yMax = useMemo(() => {
        let max = 0;
        records.forEach(r => (r.series || []).forEach(p => { if (p.mbps > max) max = p.mbps; }));
        return Math.max(5, Math.ceil((max * 1.1) / 5) * 5);
    }, [records]);

    // ---- Empty state ---------------------------------------------------------
    if (records.length === 0) {
        return (
            <div className="sd-page">
                <div className="sd-head">
                    <h1 className="sd-title">Scheduler Dashboard</h1>
                    <p className="sd-subtitle">Results from the Test Runner appear here.</p>
                </div>
                <div className="sd-empty">
                    <div className="sd-empty-icon">📊</div>
                    <h3>No results yet</h3>
                    <p>
                        Go to the <strong>Test Runner</strong> page, choose a scheduler and a
                        server, and run a test. When it finishes, the results show up here.
                    </p>
                </div>
            </div>
        );
    }

    const record = results[selected] || records[0];
    const stats = record.stats || { avg: 0, max: 0, min: 0, latest: 0 };
    const series = record.series || [];

    // Subflow interfaces: prefer the saved list, else discover from the series keys.
    const ifaces = (record.ifaces && record.ifaces.length)
        ? record.ifaces
        : (series.length
            ? Object.keys(series[series.length - 1]).filter(k => k !== 't' && k !== 'mbps')
            : []);
    const subflowRtt = record.subflowRtt || {};

    // Per-subflow throughput summarised across the whole run. Reading only the
    // final sample made finished runs look idle, because iperf3's last second is
    // the connection winding down (≈0 bytes). Average + peak over the run
    // represent what each subflow actually carried.
    const round2 = (n) => Number(n.toFixed(2));
    const subflowStats = {};
    ifaces.forEach(iface => {
        const vals = series.map(p => Number(p[iface] || 0));
        const avg = vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : 0;
        subflowStats[iface] = {
            avg: round2(avg),
            max: round2(vals.length ? Math.max(...vals) : 0),
        };
    });

    return (
        <div className="sd-page">
            <div className="sd-head">
                <h1 className="sd-title">Scheduler Dashboard</h1>
                <p className="sd-subtitle">
                    {records.length} scheduler{records.length !== 1 ? 's' : ''} tested — {ifaces.length} subflow{ifaces.length !== 1 ? 's' : ''} on this run, from the Test Runner
                </p>
            </div>

            {/* Controls */}
            <div className="sd-controls">
                <div>
                    <label className="sd-field-label">SCHEDULER</label>
                    <select
                        className="sd-select"
                        value={record.label}
                        onChange={(e) => setSelected(e.target.value)}
                    >
                        {records.map(r => (
                            <option key={r.label} value={r.label}>{r.label}</option>
                        ))}
                    </select>
                </div>

                <div className={`sd-badge ${record.demo ? 'sd-badge--demo' : 'sd-badge--live'}`}>
                    {record.demo ? 'Demo data' : 'Live data'}
                </div>

            </div>

            {/* Summary stats */}
            <div className="sd-stats">
                <StatCard label="Latest" value={`${stats.latest} Mbps`} color="#0D9488" />
                <StatCard label="Average" value={`${stats.avg} Mbps`} color="#2196F3" />
                <StatCard label="Max" value={`${stats.max} Mbps`} color="#4CAF50" />
                <StatCard label="Min" value={`${stats.min} Mbps`} color="#9C27B0" />
            </div>

            {/* Run metadata */}
            <div className="sd-meta">
                <Meta label="Target" value={record.target} />
                <Meta label="Duration" value={`${record.duration}s`} />
                <Meta label="Avg throughput" value={`${record.summary?.throughput_mbps ?? stats.avg} Mbps`} />
                <Meta label="Retransmits" value={record.summary?.retransmits ?? '—'} />
                <Meta label="Run at" value={new Date(record.timestamp).toLocaleString()} />
            </div>

            {/* Throughput over time: total + one line per subflow */}
            <div className="sd-card">
                <h3 className="sd-card-title">{record.label} — Throughput Over Time</h3>
                <ResponsiveContainer width="100%" height={300}>
                    <LineChart data={series}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#E2E8F0" />
                        <XAxis dataKey="t" stroke="#94A3B8"
                            label={{ value: 'seconds', position: 'insideBottom', offset: -3 }} />
                        <YAxis domain={[0, yMax]} stroke="#94A3B8"
                            label={{ value: 'Mbps', angle: -90, position: 'insideLeft' }} />
                        <Tooltip />
                        <Legend />
                        {ifaces.map((iface, i) => (
                            <Line key={iface} type="monotone" dataKey={iface}
                                stroke={subflowColor(i)} strokeWidth={2} dot={false}
                                name={iface} isAnimationActive={false} />
                        ))}
                        <Line type="monotone" dataKey="mbps" stroke="#0D9488" strokeWidth={3}
                            dot={false} name="Total" isAnimationActive={false} />
                    </LineChart>
                </ResponsiveContainer>
            </div>

            {/* Per-subflow breakdown: latest throughput + RTT for each interface */}
            {ifaces.length > 0 && (
                <div className="sd-card">
                    <h3 className="sd-card-title">Per-Subflow Metrics</h3>
                    <div className="sd-subflows">
                        {ifaces.map((iface, i) => (
                            <div key={iface} className="sd-subflow" style={{ borderColor: subflowColor(i) }}>
                                <div className="sd-subflow-name" style={{ color: subflowColor(i) }}>{iface}</div>
                                <div className="sd-subflow-row">
                                    <span>Avg throughput</span>
                                    <strong>{(subflowStats[iface]?.avg ?? 0).toFixed(2)} Mbps</strong>
                                </div>
                                <div className="sd-subflow-row">
                                    <span>Peak</span>
                                    <strong>{(subflowStats[iface]?.max ?? 0).toFixed(2)} Mbps</strong>
                                </div>
                                <div className="sd-subflow-row">
                                    <span>RTT</span>
                                    <strong>{subflowRtt[iface] != null ? `${subflowRtt[iface]} ms` : '—'}</strong>
                                </div>
                                <div className="sd-subflow-row">
                                    <span>Status</span>
                                    <strong>{(subflowStats[iface]?.max ?? 0) > 0 ? 'Active' : 'Idle'}</strong>
                                </div>
                            </div>
                        ))}
                    </div>
                </div>
            )}

            {/* Comparison across every scheduler that has a result */}
            <div className="sd-card">
                <div className="sd-card-header">
                    <h3 className="sd-card-title">All Runs</h3>
                    <button
                        className="sd-clear"
                        onClick={handleClear}
                        disabled={checked.size === 0}
                    >
                        {checked.size === 0 ? 'Clear selected' : `Clear selected (${checked.size})`}
                    </button>
                </div>
                <table className="sd-table">
                    <thead>
                        <tr>
                            <th>
                                <input
                                    type="checkbox"
                                    checked={records.length > 0 && checked.size === records.length}
                                    onChange={toggleAll}
                                    title="Select all"
                                />
                            </th>
                            <th>Scheduler</th>
                            <th>Target</th>
                            <th>Duration</th>
                            <th>Avg</th>
                            <th>Max</th>
                            <th>Latest</th>
                            <th>Retransmits</th>
                            <th>Mode</th>
                            <th>Run at</th>
                        </tr>
                    </thead>
                    <tbody>
                        {records.map(r => (
                            <tr
                                key={r.label}
                                className={r.label === record.label ? 'sd-row--active' : ''}
                                onClick={() => setSelected(r.label)}
                            >
                                <td onClick={e => e.stopPropagation()}>
                                    <input
                                        type="checkbox"
                                        checked={checked.has(r.label)}
                                        onChange={() => toggleCheck(r.label)}
                                    />
                                </td>
                                <td>{r.label}</td>
                                <td>{r.target}</td>
                                <td>{r.duration}s</td>
                                <td>{r.stats?.avg} Mbps</td>
                                <td>{r.stats?.max} Mbps</td>
                                <td>{r.stats?.latest} Mbps</td>
                                <td>{r.summary?.retransmits ?? '—'}</td>
                                <td>{r.demo ? 'Demo' : 'Live'}</td>
                                <td>{new Date(r.timestamp).toLocaleTimeString()}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </div>
    );
};

const StatCard = ({ label, value, color }) => (
    <div className="sd-stat" style={{ borderColor: color }}>
        <div className="sd-stat-label">{label}</div>
        <div className="sd-stat-value" style={{ color }}>{value}</div>
    </div>
);

const Meta = ({ label, value }) => (
    <div className="sd-meta-item">
        <div className="sd-meta-label">{label}</div>
        <div className="sd-meta-value">{value}</div>
    </div>
);

export default SchedulerDashboardPage;
