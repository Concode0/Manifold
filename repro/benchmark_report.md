# MANIFOLD BENCHMARK REPORT
Date: 2026-03-06 13:51:17

### SUMMARY OF STATISTICAL REFINEMENTS
1. **Trimmed Means**: 10% trim applied to suppress outliers.
2. **Winsorized Variance**: Used for robust Confidence Interval calculation.
3. **Yuen-Welch Test**: Robust comparison of trimmed means.
4. **Raw Skewness**: Calculated from the full sample to capture true tail behavior.

#### Suite A: Routing Analysis
| Algorithm | Heterogeneous (±σ) | Homogeneous (±σ) |
| :--- | :--- | :--- |
| Manifold (L3) | 1.2102 (±1.1840, Skew:1.16) | 0.0646 (±0.0514, Skew:-0.05) |
| P2C (Sampling) | 319.2458 (±82.7604, Skew:0.53) | 0.1492 (±0.0832, Skew:1.80) |
| Round Robin | 19393.2192 (±2327.1677, Skew:-0.34) | 15.6411 (±13.4620, Skew:0.89) |

**Robust P-Value (Yuen-Welch):** p = 2.5710e-05

#### Suite B: Mitosis Efficiency (Execution Time in ms)
| Shards | Average Time (ms) ±σ | Status |
| :--- | :--- | :--- |
| 1 | 521.93 (±0.71) | OK |
| 2 | 516.74 (±1.39) | OK |
| 4 | 525.46 (±2.30) | OK |
| 8 | 541.35 (±4.28) | OK |
| 16 | 566.93 (±5.15) | OK |

#### Suite C: Consensus Quorum Scaling (Latency in ms)
| Nodes | Avg Commit Latency (ms) ±σ |
| :--- | :--- |
| 1 | 0.4314 (±0.0617) |
| 3 | 0.7915 (±0.0508) |
| 5 | 0.8868 (±0.1483) |

#### Suite D: Data Plane Justification (Execution Time)
| Workload | Elixir VM (±σ) | Rust NIF (±σ) | Speedup |
| :--- | :--- | :--- | :--- |
| Micro (10 ops) | 94.00 ns (±0.00ms) | 490.98 ns (±0.00ms) | 0.19x |
| Med (10k ops) | 125.22 μs (±0.00ms) | 216.33 μs (±0.01ms) | 0.58x |
| Heavy (1M ops) | 18.47 ms (±0.18ms) | 21.91 ms (±0.64ms) | 0.84x |

#### Suite E: Tail Latency (5000 Tasks)
| Algorithm | Availability | p50 (±CI) | p99 (±CI) | Raw Skew |
| :--- | :--- | :--- | :--- | :--- |
| Manifold | 100.0% | 2.14 (±0.39) | 81.84 (±16.00) | -0.43 |
| P2c | 50.0% | 15005.11 (±14774.59) | **TIMEOUT** | nan |