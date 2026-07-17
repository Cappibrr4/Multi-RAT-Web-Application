// ---------------------------------------------------------------------------
// Shared store for iperf3 test results.
//
// The Test Runner page writes a record here when a run finishes; the Scheduler
// Dashboard page reads them back. localStorage is used so results survive
// navigation between the two routes (and a page refresh).
//
// Shape of one record (keyed by scheduler label, latest run wins):
//   {
//     label, scheduler, target, duration, demo,
//     summary: { throughput_mbps, retransmits, ... },
//     series: [{ t, mbps }, ...],
//     stats:  { avg, max, min, latest },
//     timestamp
//   }
// ---------------------------------------------------------------------------

const KEY = 'mrat_test_results';

export function loadTestResults() {
    try {
        return JSON.parse(localStorage.getItem(KEY)) || {};
    } catch (e) {
        return {};
    }
}

export function saveTestResult(record) {
    const all = loadTestResults();
    all[record.label] = record;            // latest run per scheduler replaces the old
    localStorage.setItem(KEY, JSON.stringify(all));
}

export function clearTestResults() {
    localStorage.removeItem(KEY);
}

// Build the { avg, max, min, latest } summary from a [{ t, mbps }] series.
export function computeStats(series) {
    const vals = series.map(p => p.mbps);
    if (vals.length === 0) return { avg: 0, max: 0, min: 0, latest: 0 };
    const round = (n) => Number(n.toFixed(2));
    return {
        avg: round(vals.reduce((a, b) => a + b, 0) / vals.length),
        max: round(Math.max(...vals)),
        min: round(Math.min(...vals)),
        latest: round(vals[vals.length - 1]),
    };
}
