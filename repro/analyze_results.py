import os
import csv
import math
import statistics
import scipy.stats
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
import time

sns.set_theme(style="whitegrid")

TIMEOUT_THRESHOLD = 30000.0

class Stats:
    def __init__(self, values, trim_ratio=0.1):
        self.raw_values = sorted(values)
        self.n_total = len(self.raw_values)
        
        try:
            self.skew = scipy.stats.skew(self.raw_values) if self.n_total >= 3 else 0
        except Exception:
            self.skew = 0

        self.timeout_count = sum(1 for v in self.raw_values if v >= TIMEOUT_THRESHOLD)
        self.availability = (1.0 - (self.timeout_count / self.n_total)) * 100 if self.n_total > 0 else 100.0
        
        k = int(self.n_total * trim_ratio)
        if k < 1 and self.n_total >= 3: k = 1
        
        if self.n_total > 2 * k:
            self.trimmed = self.raw_values[k:-k]
            self.k = k
        else:
            self.trimmed = self.raw_values
            self.k = 0
        
        self.n = len(self.trimmed)
        if self.n > 0:
            self.avg = sum(self.trimmed) / self.n
            winsorized = list(self.trimmed)
            if self.k > 0:
                low_val, high_val = self.trimmed[0], self.trimmed[-1]
                winsorized = [low_val] * self.k + winsorized + [high_val] * self.k
            
            self.winsorized_stdev = statistics.stdev(winsorized) if len(winsorized) > 1 else 0
            g = self.k / self.n_total
            try:
                df = self.n - 1
                t_score = scipy.stats.t.ppf(0.975, df) if df > 0 else 0
                se_trimmed = self.winsorized_stdev / ((1 - 2*g) * math.sqrt(self.n_total))
                self.ci = t_score * se_trimmed
                self.stdev = self.winsorized_stdev 
            except Exception:
                self.ci = 0
                self.stdev = statistics.stdev(self.trimmed) if self.n > 1 else 0
        else:
            self.avg = 0
            self.stdev = 0
            self.ci = 0

def yuen_welch_test(s1, s2):
    if s1.n < 2 or s2.n < 2: return 1.0
    g1, g2 = s1.k / s1.n_total, s2.k / s2.n_total
    d1 = (s1.winsorized_stdev ** 2) / ((1 - 2*g1)**2 * s1.n_total)
    d2 = (s2.winsorized_stdev ** 2) / ((1 - 2*g2)**2 * s2.n_total)
    if (d1 + d2) == 0: return 0.0 if s1.avg != s2.avg else 1.0
    t_stat = abs(s1.avg - s2.avg) / math.sqrt(d1 + d2)
    num = (d1 + d2) ** 2
    den = (d1**2 / (s1.n - 1)) + (d2**2 / (s2.n - 1))
    p_val = 2 * (1 - scipy.stats.t.cdf(t_stat, num / den))
    return p_val

def process_results(num_runs=10):
    raw_data = {}
    runs_dir = os.path.join("repro", "benchmark_runs")
    suite_files = ["benchmark_suite_a_hete", "benchmark_suite_a_homo", "benchmark_suite_b", 
                   "benchmark_suite_c", "benchmark_suite_d", "benchmark_suite_e_1000", "benchmark_suite_e_5000"]
    
    for suite in suite_files:
        raw_data[suite] = {}
        for i in range(1, num_runs + 1):
            filepath = os.path.join(runs_dir, f"{suite}_{i}.csv")
            if not os.path.exists(filepath): continue
            with open(filepath, 'r') as f:
                reader = csv.reader(f)
                try: next(reader)
                except Exception: continue
                try:
                    if suite == "benchmark_suite_d":
                        for row in reader:
                            if not row or len(row) < 5: continue
                            key = f"{row[0]}|{row[1]}"
                            val = float(row[4])
                            if key not in raw_data[suite]: raw_data[suite][key] = []
                            raw_data[suite][key].append(val)
                    elif suite.startswith("benchmark_suite_e"):
                        for row in reader:
                            if not row or len(row) < 10: continue
                            algo = row[0]
                            for idx, p_name in [(3, "p50"), (6, "p95"), (7, "p99"), (9, "max")]:
                                key = f"{algo}|{p_name}"
                                val = float(row[idx])
                                if key not in raw_data[suite]: raw_data[suite][key] = []
                                raw_data[suite][key].append(val)
                    else:
                        for row in reader:
                            if not row or len(row) < 2: continue
                            key, val = row[0], float(row[1])
                            if key not in raw_data[suite]: raw_data[suite][key] = []
                            raw_data[suite][key].append(val)
                except Exception: continue
    results = {suite: {key: Stats(values) for key, values in keys.items()} for suite, keys in raw_data.items()}
    return results

def format_stat(s):
    return f"{s.avg:.4f} (±{s.stdev:.4f}, Skew:{s.skew:.2f})"

def format_time_ns(ns):
    if ns < 1000: return f"{ns:.2f} ns"
    if ns < 1000000: return f"{ns/1000:.2f} μs"
    if ns < 1000000000: return f"{ns/1000000:.2f} ms"
    return f"{ns/1000000000:.2f} s"

def generate_charts(results):
    charts_dir = os.path.join("repro", "benchmark_charts")
    if not os.path.exists(charts_dir): os.makedirs(charts_dir)
    
    suite_a_hete = results.get("benchmark_suite_a_hete", {})
    if suite_a_hete:
        plt.figure(figsize=(10, 6))
        algos = ["Manifold (L3)", "P2C (Sampling)", "Round Robin"]
        averages = [suite_a_hete[a].avg for a in algos if a in suite_a_hete]
        stdevs = [suite_a_hete[a].stdev for a in algos if a in suite_a_hete]
        if averages:
            labels = [f"{a}\n(TIMEOUT)" if suite_a_hete[a].timeout_count > 0 else a for a in algos if a in suite_a_hete]
            sns.barplot(x=labels, y=averages, hue=labels, palette="viridis", legend=False)
            plt.errorbar(x=range(len(averages)), y=averages, yerr=stdevs, fmt='none', c='black', capsize=5)
            plt.yscale('log')
            plt.title("Suite A: Routing Variance")
            plt.savefig(os.path.join(charts_dir, "suite_a_hete.png"))
        plt.close()

    suite_b = results.get("benchmark_suite_b", {})
    if suite_b:
        plt.figure(figsize=(10, 6))
        shards = sorted([s for s in suite_b.keys()], key=lambda x: int(float(x)))
        if shards:
            sns.lineplot(x=[int(float(s)) for s in shards], y=[suite_b[s].avg for s in shards], marker='o')
            plt.yscale('log')
            plt.title("Suite B: Mitosis Efficiency")
            plt.savefig(os.path.join(charts_dir, "suite_b.png"))
        plt.close()

    suite_e_5000 = results.get("benchmark_suite_e_5000", {})
    if suite_e_5000:
        plt.figure(figsize=(12, 6))
        data = []
        for m in ["p50", "p95", "p99"]:
            for a in ["manifold", "p2c"]:
                key = f"{a}|{m}"
                if key in suite_e_5000:
                    label = f"{a.capitalize()}{' (TIMEOUT)' if suite_e_5000[key].timeout_count > 0 else ''}"
                    data.append({"Metric": m.upper(), "Algorithm": label, "Latency": suite_e_5000[key].avg})
        if data:
            import pandas as pd
            df = pd.DataFrame(data)
            sns.barplot(data=df, x="Metric", y="Latency", hue="Algorithm")
            plt.yscale('log')
            plt.title("Suite E: Tail Latency")
            plt.savefig(os.path.join(charts_dir, "suite_e_tail.png"))
        plt.close()

def generate_markdown(results):
    output = ["# MANIFOLD BENCHMARK REPORT", f"Date: {time.strftime('%Y-%m-%d %H:%M:%S')}", 
              "\n### SUMMARY OF STATISTICAL REFINEMENTS",
              "1. **Trimmed Means**: 10% trim applied to suppress outliers.",
              "2. **Winsorized Variance**: Used for robust Confidence Interval calculation.",
              "3. **Yuen-Welch Test**: Robust comparison of trimmed means.",
              "4. **Raw Skewness**: Calculated from the full sample to capture true tail behavior.",
              "\n#### Suite A: Routing Analysis", "| Algorithm | Heterogeneous (±σ) | Homogeneous (±σ) |", "| :--- | :--- | :--- |"]
    
    suite_a_hete, suite_a_homo = results.get("benchmark_suite_a_hete", {}), results.get("benchmark_suite_a_homo", {})
    for label, key in [("Manifold (L3)", "Manifold (L3)"), ("P2C (Sampling)", "P2C (Sampling)"), ("Round Robin", "Round Robin")]:
        h_stat = format_stat(suite_a_hete[key]) if key in suite_a_hete else "N/A"
        o_stat = format_stat(suite_a_homo[key]) if key in suite_a_homo else "N/A"
        output.append(f"| {label} | {h_stat} | {o_stat} |")
    
    if "Manifold (L3)" in suite_a_hete and "P2C (Sampling)" in suite_a_hete:
        pv = yuen_welch_test(suite_a_hete["Manifold (L3)"], suite_a_hete["P2C (Sampling)"])
        output.append(f"\n**Robust P-Value (Yuen-Welch):** p = {pv:.4e}")

    output.append("\n#### Suite B: Mitosis Efficiency (Execution Time in ms)")
    output.append("| Shards | Average Time (ms) ±σ | Status |")
    output.append("| :--- | :--- | :--- |")
    suite_b = results.get("benchmark_suite_b", {})
    shards_keys = sorted(suite_b.keys(), key=lambda x: int(float(x)))
    for s in shards_keys:
        stat = suite_b[s]
        status = "OK" if stat.timeout_count == 0 else f"TIMEOUT ({stat.timeout_count})"
        output.append(f"| {int(float(s))} | {stat.avg:.2f} (±{stat.stdev:.2f}) | {status} |")

    output.append("\n#### Suite C: Consensus Quorum Scaling (Latency in ms)")
    output.append("| Nodes | Avg Commit Latency (ms) ±σ |")
    output.append("| :--- | :--- |")
    suite_c = results.get("benchmark_suite_c", {})
    nodes_keys = sorted(suite_c.keys(), key=lambda x: int(float(x)))
    for n in nodes_keys:
        stat = suite_c[n]
        output.append(f"| {int(float(n))} | {stat.avg:.4f} (±{stat.stdev:.4f}) |")

    output.append("\n#### Suite D: Data Plane Justification (Execution Time)")
    output.append("| Workload | Elixir VM (±σ) | Rust NIF (±σ) | Speedup |")
    output.append("| :--- | :--- | :--- | :--- |")
    suite_d = results.get("benchmark_suite_d", {})
    workloads = ["Micro (10 ops)", "Med (10k ops)", "Heavy (1M ops)"]
    for w in workloads:
        evm = suite_d.get(f"Elixir VM|{w}")
        rnif = suite_d.get(f"Rust NIF|{w}")
        if evm and rnif:
            evm_str = f"{format_time_ns(evm.avg)} (±{evm.stdev/1000000:.2f}ms)"
            rnif_str = f"{format_time_ns(rnif.avg)} (±{rnif.stdev/1000000:.2f}ms)"
            speedup = f"{evm.avg / rnif.avg:.2f}x"
            output.append(f"| {w} | {evm_str} | {rnif_str} | {speedup} |")

    output.append("\n#### Suite E: Tail Latency (5000 Tasks)")
    output.append("| Algorithm | Availability | p50 (±CI) | p99 (±CI) | Raw Skew |")
    output.append("| :--- | :--- | :--- | :--- | :--- |")
    suite_e = results.get("benchmark_suite_e_5000", {})
    for a in ["manifold", "p2c"]:
        p50, p99 = suite_e.get(f"{a}|p50"), suite_e.get(f"{a}|p99")
        if p50 and p99:
            def f(s): return f"{s.avg:.2f} (±{s.ci:.2f})" if s.avg < TIMEOUT_THRESHOLD else "**TIMEOUT**"
            output.append(f"| {a.capitalize()} | {p50.availability:.1f}% | {f(p50)} | {f(p99)} | {p99.skew:.2f} |")

    with open(os.path.join("repro", "benchmark_report.md"), "w") as f: f.write("\n".join(output))

if __name__ == "__main__":
    results = process_results(10)
    if any(results.values()):
        generate_markdown(results)
        generate_charts(results)
