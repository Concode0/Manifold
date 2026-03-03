# Manifold: Geometric Distributed OS

Manifold is a research framework for distributed task scheduling using **Minkowski Metrics**. By treating node resources (Capacity, Memory, Latency) as dimensions, Manifold uses geometric distance to balance tasks in heterogeneous clusters.

## Core Pillars

1.  **Minkowski Routing:** Implements an $L_3$ metric ($(|C_1-C_2|^3 + |M_1-M_2|^3)^{1/3}$) with exponential load distortion. This penalizes single-dimension resource outliers more heavily than Euclidean ($L_2$) distance.
2.  **Task Mitosis:** A pipeline comprising **Static Instruction Analysis** (calculating deterministic effort scores in Rust) and **Proportional Heterogeneous Sharding** (allocating work-ranges sized relative to candidate node capacities).
3.  **Hybrid Architecture:** A **Control Plane** (Elixir/OTP) for fault-tolerant orchestration and an **Accelerated Data Plane** (Rust/NIF) for native mathematical execution.
4.  **Epidemic Gossip:** A batch-based directory propagation protocol ensuring cluster-wide state convergence through recursive neighbor synchronization.

---

## Performance Metrics (Benchmarks)

*Generated on a simulated 5-node cluster (Apple M4 Environment).*

### **Suite A: Routing Variance**
Measures how evenly the load-to-capacity ratio is distributed across nodes. Lower variance indicates more stable balancing.

#### **Heterogeneous Cluster** (Diverse capacities: 1.0 to 20.0)
| Algorithm | Load Ratio Variance |
| :--- | :--- |
| **Manifold (L3)** | **0.4104** |
| Power of Two Choices (P2C) | 143.0720 |
| Round Robin | 17075.6904 |

#### **Homogeneous Cluster** (All nodes equal: 10.0)
| Algorithm | Load Ratio Variance |
| :--- | :--- |
| **Manifold (L3)** | **0.1080** |
| Power of Two Choices (P2C) | 0.2400 |
| Round Robin | 9.0720 |

### **Suite B: Mitosis Efficiency (The U-Curve)**
Coordination overhead of task splitting across loopback TCP sockets (100k ops).
| Shards | Total Time (ms) |
| :--- | :--- |
| 1 (Local) | 522.24 ms |
| 2 (Predicted Optimal) | 517.05 ms |
| 4 | 530.03 ms |
| 8 | 546.30 ms |
| 16 | 573.03 ms |

### **Suite C: Consensus Latency**
Raft commit scaling for Distributed Shared Memory (DSM).
| Nodes | Avg Commit Latency (ms) |
| :--- | :--- |
| 1 | 0.48 ms |
| 3 | 0.94 ms |
| 5 | 0.86 ms |

### **Suite D: Virtual Machine Performance (1M Ops)**
| Metric | Elixir (Control Plane) | Rust (Data Plane) |
| :--- | :--- | :--- |
| **Execution Rate** | 51.44 ips | **46.04 ips** |
| **BEAM Heap Pressure** | **79.99 MB** | **0.000016 MB** |
*Note: While small-scale throughput is similar due to NIF overhead, Rust eliminates BEAM heap pressure by a factor of 5,000,000x.*

---

## Research Caveats & Analysis Notes

When analyzing the provided data, the following physical and logical constraints must be considered:

1.  **Single-Machine Bottleneck:** All benchmarks run on a single physical CPU. In Suite B, high shard counts (8+) introduce **CPU contention** and OS context-switching overhead that would not exist in a truly distributed network.
2.  **Loopback Latency:** Networking metrics use the `127.0.0.1` interface. Real-world physical network latency and switch-jitter will significantly increase the coordination cost in Suite C (Consensus).
3.  **Memory Transparency:** The "Heap Pressure" advantage in Suite D reflects only the memory managed by the Erlang Garbage Collector (GC). Rust NIF execution uses **Manual Memory Management** on the native heap, which is opaque to BEAM GC but remains part of the total system footprint.
4.  **Metric Sensitivity:** The $L_3$ metric is mathematically tuned to prioritize "Capacity Leveling." In clusters with near-zero load, the geometric distance may appear more volatile than P2C until the exponential distortion field triggers at higher load ratios.

---

## Usage

### **Run Benchmarks & Analysis**
The following command executes all research suites and generates standardized CSV outputs for further analysis.
```bash
mix run benchmark.exs
```
