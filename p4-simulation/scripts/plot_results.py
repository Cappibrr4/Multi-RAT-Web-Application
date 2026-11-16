#!/usr/bin/env python3
"""
Benchmark Results Visualizer
=============================
Reads benchmark JSON output and generates comparison charts.

Usage:
    python3 plot_results.py results/benchmark_YYYYMMDD_HHMMSS.json

Generates:
    - throughput_comparison.png
    - latency_comparison.png
    - scheduler_summary.png
"""

import json
import sys
import os

try:
    import matplotlib
    matplotlib.use('Agg')  # Non-interactive backend
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
except ImportError:
    print("Installing matplotlib...")
    os.system("pip3 install matplotlib --break-system-packages 2>/dev/null || pip3 install matplotlib")
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches


def load_results(filepath):
    with open(filepath) as f:
        return json.load(f)


def plot_throughput(data, output_dir):
    """Bar chart comparing throughput across scenarios."""
    tests = data['tests']
    scenarios = sorted(set(t['label'].split('_', 1)[1] for t in tests))

    rr_vals = []
    blest_vals = []

    for scenario in scenarios:
        for t in tests:
            if t['label'].endswith(scenario):
                tp = t['results'].get('throughput_mbps', 0)
                if t['scheduler'] == 'rr':
                    rr_vals.append(tp)
                else:
                    blest_vals.append(tp)

    x = range(len(scenarios))
    width = 0.35

    fig, ax = plt.subplots(figsize=(12, 6))
    bars1 = ax.bar([i - width/2 for i in x], rr_vals, width,
                   label='Round-Robin (P4)', color='#2196F3', edgecolor='white')
    bars2 = ax.bar([i + width/2 for i in x], blest_vals, width,
                   label='BLEST (P4)', color='#FF5722', edgecolor='white')

    ax.set_ylabel('Throughput (Mbps)', fontsize=12)
    ax.set_title('P4 Switch Scheduler: Throughput Comparison', fontsize=14, fontweight='bold')
    ax.set_xticks(list(x))
    ax.set_xticklabels([s.replace('_', '\n') for s in scenarios], fontsize=9)
    ax.legend(fontsize=11)
    ax.grid(axis='y', alpha=0.3)

    # Add value labels on bars
    for bar in bars1 + bars2:
        height = bar.get_height()
        if height > 0:
            ax.text(bar.get_x() + bar.get_width()/2., height + 0.2,
                    f'{height:.1f}', ha='center', va='bottom', fontsize=8)

    plt.tight_layout()
    path = os.path.join(output_dir, 'throughput_comparison.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  Saved: {path}")


def plot_latency(data, output_dir):
    """Bar chart comparing RTT across scenarios."""
    tests = data['tests']
    scenarios = sorted(set(t['label'].split('_', 1)[1] for t in tests))

    rr_vals = []
    blest_vals = []

    for scenario in scenarios:
        for t in tests:
            if t['label'].endswith(scenario):
                rtt = t['results'].get('avg_rtt_ms', 0)
                if t['scheduler'] == 'rr':
                    rr_vals.append(rtt)
                else:
                    blest_vals.append(rtt)

    x = range(len(scenarios))
    width = 0.35

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.bar([i - width/2 for i in x], rr_vals, width,
           label='Round-Robin (P4)', color='#2196F3', edgecolor='white')
    ax.bar([i + width/2 for i in x], blest_vals, width,
           label='BLEST (P4)', color='#FF5722', edgecolor='white')

    ax.set_ylabel('Average RTT (ms)', fontsize=12)
    ax.set_title('P4 Switch Scheduler: Latency Comparison', fontsize=14, fontweight='bold')
    ax.set_xticks(list(x))
    ax.set_xticklabels([s.replace('_', '\n') for s in scenarios], fontsize=9)
    ax.legend(fontsize=11)
    ax.grid(axis='y', alpha=0.3)

    plt.tight_layout()
    path = os.path.join(output_dir, 'latency_comparison.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  Saved: {path}")


def plot_summary(data, output_dir):
    """Multi-metric summary chart."""
    tests = data['tests']

    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle('P4 Switch-Based Multipath Scheduler — Full Benchmark Summary',
                 fontsize=14, fontweight='bold')

    metrics = [
        ('throughput_mbps', 'Throughput (Mbps)', axes[0, 0]),
        ('avg_rtt_ms', 'Avg RTT (ms)', axes[0, 1]),
        ('jitter_ms', 'Jitter (ms)', axes[1, 0]),
        ('loss_percent', 'Packet Loss (%)', axes[1, 1]),
    ]

    scenarios = sorted(set(t['label'].split('_', 1)[1] for t in tests))

    for metric_key, metric_label, ax in metrics:
        rr_vals = []
        blest_vals = []

        for scenario in scenarios:
            for t in tests:
                if t['label'].endswith(scenario):
                    val = t['results'].get(metric_key)
                    if val is None or val < 0:
                        val = 0
                    if t['scheduler'] == 'rr':
                        rr_vals.append(val)
                    else:
                        blest_vals.append(val)

        x = range(len(scenarios))
        width = 0.35
        ax.bar([i - width/2 for i in x], rr_vals, width,
               label='RR', color='#2196F3', edgecolor='white')
        ax.bar([i + width/2 for i in x], blest_vals, width,
               label='BLEST', color='#FF5722', edgecolor='white')
        ax.set_ylabel(metric_label, fontsize=10)
        ax.set_xticks(list(x))
        ax.set_xticklabels([s.replace('_', '\n') for s in scenarios],
                          fontsize=7)
        ax.legend(fontsize=8)
        ax.grid(axis='y', alpha=0.3)

    plt.tight_layout()
    path = os.path.join(output_dir, 'scheduler_summary.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  Saved: {path}")


def main():
    if len(sys.argv) < 2:
        # Find most recent results file
        results_dir = os.path.join(os.path.dirname(__file__), '..', 'results')
        if os.path.isdir(results_dir):
            files = sorted([f for f in os.listdir(results_dir)
                          if f.startswith('benchmark_') and f.endswith('.json')])
            if files:
                filepath = os.path.join(results_dir, files[-1])
            else:
                print("No benchmark results found. Run run_benchmark.sh first.")
                sys.exit(1)
        else:
            print("Usage: python3 plot_results.py <results.json>")
            sys.exit(1)
    else:
        filepath = sys.argv[1]

    print(f"Loading: {filepath}")
    data = load_results(filepath)

    output_dir = os.path.dirname(filepath)
    print(f"Output:  {output_dir}/\n")

    print("Generating charts...")
    plot_throughput(data, output_dir)
    plot_latency(data, output_dir)
    plot_summary(data, output_dir)
    print("\nDone!")


if __name__ == '__main__':
    main()
