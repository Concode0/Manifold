# Manifold: Geometric Distributed OS

Manifold is a research framework for distributed task scheduling using **Minkowski Metrics**. By treating node resources (Capacity, Memory, Latency) as dimensions, Manifold uses geometric distance to balance tasks in heterogeneous clusters.

## Core Pillars

1.  **Minkowski Routing:** Implements an $L_3$ metric with exponential load distortion to penalize resource outliers.
2.  **Task Mitosis:** Proportional heterogeneous sharding based on static instruction analysis.
3.  **Hybrid Architecture:** Control Plane (Elixir/OTP) and Accelerated Data Plane (Rust/NIF).
4.  **Epidemic Gossip:** O(log N) state convergence via recursive neighbor synchronization.

---

## Performance Metrics

*Results processed using Yuen-Welch tests and Winsorized variance for robust estimation.*

### **Suite A: Routing Variance**
| Algorithm         | Heterogeneous (±Winsorized σ) | Homogeneous (±Winsorized σ) |
| :---------------- | :---------------------------- | :-------------------------- |
| **Manifold (L3)** | **1.2102 (±1.18)**            | **0.0646 (±0.05)**          |
| P2C (Sampling)    | 319.2458 (±82.76)             | 0.1492 (±0.08)              |
| Round Robin       | 19393.2192 (±2327.17)         | 15.6411 (±13.46)            |
*Robust P-Value (Manifold vs P2C): p = 2.57e-05*

### **Suite E: Tail Latency (5000 Tasks)**
| Metric           | Manifold (L3)         | P2C (Sampling)            |
| :--------------- | :-------------------- | :------------------------ |
| **Availability** | **100.0%**            | 50.0% (Systemic Collapse) |
| **p50 (Median)** | **2.14 ms (±0.39)**   | 15005.11 ms (±14774.59)   |
| **p99 (Tail)**   | **81.84 ms (±16.00)** | **TIMEOUT**               |
| **Raw Skewness** | **-0.43**             | N/A                       |

---

## Usage Guide

### **1. Elixir/Rust Core (Production Prototype)**
The primary research implementation using Elixir for the control plane and Rust for the data plane.

#### **Run Benchmarks & Analysis**
```bash
# Fetch dependencies and compile
mix deps.get
mix compile

# Run all benchmark suites
mix run benchmark.exs

# Run benchmarks 10 times automatically and save it into labeled csv
uv run repro/run_benchmarks.py

# Generate robust statistical report and charts
uv run repro/analyze_results.py
```

### **2. Python Proof-of-Concept (POC)**
A standalone, pure-Python implementation located in `poc_python/`. It demonstrates geometric routing and task mitosis using standard libraries.

#### **Running the POC Cluster**
```bash
# 1. Launch the cluster (starts NODE_COUNT processes)
uv run poc_python/launcher.py

# 2. In a separate terminal, submit a workload
uv run poc_python/client.py
```
*Note: The POC uses Node 9001 as a bootstrap seed. It simulates a 16-node cluster by default.*

---

## Statistical Rigor & Research Caveats

The Manifold evaluation pipeline utilizes advanced robust statistics to ensure reproducibility:

1.  **Trimming & Winsorization:** 10% trimming is applied to remove transient noise. Confidence Intervals are calculated using **Winsorized Variance** to prevent underestimation of standard error.
2.  **Yuen-Welch Testing:** We reject standard t-tests in favor of Yuen's method for comparing trimmed means, providing valid p-values under non-normal latency distributions.
3.  **Raw Skewness:** Unlike many benchmarks that report only means, we analyze raw skewness to expose the true extent of the latency tail before trimming.
4.  **Single-Machine Bottleneck:** Note that all results are from a simulated environment on an Apple M4; real-world network jitter will increase absolute values but is expected to maintain relative delta.
5.  **Loopback Latency:** Networking metrics use the `127.0.0.1` interface. Real-world physical network latency and switch-jitter will significantly increase the coordination cost in Suite C (Consensus).
6.  **Memory Transparency:** The "Heap Pressure" advantage in Suite D reflects only the memory managed by the Erlang Garbage Collector (GC). Rust NIF execution uses **Manual Memory Management** on the native heap, which is opaque to BEAM GC but remains part of the total system footprint.
7.  **Metric Sensitivity:** The $L_3$ metric is mathematically tuned to prioritize "Capacity Leveling." In clusters with near-zero load, the geometric distance may appear more volatile than P2C until the exponential distortion field triggers at higher load ratios.


---
*Created for the purpose of exploring geometric routing in heterogeneous computing environments.*
