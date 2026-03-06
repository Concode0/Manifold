# MANIFOLD BENCHMARK REPORT
Date: 2026-03-06 18:36:49

### SUMMARY OF STATISTICAL REFINEMENTS
1. **Trimmed Means**: 10% trim applied to suppress outliers.
2. **Winsorized Variance**: Used for robust Confidence Interval calculation.
3. **Yuen-Welch Test**: Robust comparison of trimmed means.
4. **Raw Skewness**: Calculated from the full sample to capture true tail behavior.

#### Suite A: Routing Analysis
| Algorithm | Heterogeneous (±σ) | Homogeneous (±σ) |
| :--- | :--- | :--- |
| Manifold (L3) | 3.1074 (±1.5433, Skew:0.59) | 0.0655 (±0.0526, Skew:0.57) |
| P2C (Sampling) | 292.2390 (±85.0294, Skew:-0.18) | 0.1436 (±0.0828, Skew:-0.25) |
| Round Robin | 75.0889 (±30.3865, Skew:0.67) | 15.4841 (±9.8758, Skew:0.27) |

**Robust P-Value (Heterogeneous):** p = 5.7021e-05
**Robust P-Value (Homogeneous):** p = 6.7296e-02

#### Suite B: Mitosis Efficiency (Execution Time in ms)
| Shards | Average Time (ms) ±σ | Status |
| :--- | :--- | :--- |
| 1 | 521.59 (±1.19) | OK |
| 2 | 517.16 (±1.15) | OK |
| 4 | 525.63 (±1.92) | OK |
| 8 | 542.11 (±4.03) | OK |
| 16 | 563.29 (±4.51) | OK |

#### Suite C: Consensus Quorum Scaling (Latency in ms)
| Nodes | Avg Commit Latency (ms) ±σ |
| :--- | :--- |
| 1 | 0.4132 (±0.0661) |
| 3 | 0.8425 (±0.0645) |
| 5 | 0.9478 (±0.1537) |

#### Suite D: Data Plane Justification (Execution Time)
| Workload | Elixir VM (±σ) | Rust NIF (±σ) | Speedup |
| :--- | :--- | :--- | :--- |
| Micro (10 ops) | 95.30 ns (±0.00ms) | 489.44 ns (±0.00ms) | 0.19x |
| Med (10k ops) | 126.31 μs (±0.00ms) | 209.61 μs (±0.00ms) | 0.60x |
| Heavy (1M ops) | 18.53 ms (±0.15ms) | 21.28 ms (±0.17ms) | 0.87x |

#### Suite E: Tail Latency (5000 Tasks)
| Algorithm | Availability | p50 (±CI) | p99 (±CI) | Raw Skew |
| :--- | :--- | :--- | :--- | :--- |
| Manifold | 100.0% | 2.00 (±0.02) | 87.64 (±11.39) | 0.49 |
| P2c | 30.0% | 22512.69 (±13529.36) | **TIMEOUT** | nan |