# Manifold: The Geometric Distributed OS

![Python](https://img.shields.io/badge/python-3.7+-blue.svg) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) ![Status: Prototype](https://img.shields.io/badge/status-prototype-blue.svg)

<p align="center">
  <img src="assets/MANIFOLD_PoC.gif" width="85%" />
</p>

Manifold is a research prototype of a distributed operating system that leverages geometric principles to manage heterogeneity and scale. It demonstrates a novel approach to task scheduling, routing, and consensus by mapping compute nodes into a high-dimensional feature space (the "Manifold") and routing workloads based on geometric distance rather than traditional identifiers.


## 🌌 Core Philosophy

In modern distributed systems, "heterogeneity" is the norm. Nodes vary in CPU power, memory, bandwidth, and current load. Manifold treats these attributes as coordinates in a multi-dimensional metric space.

*   **Geometry over Topology:** Nodes don't just "know" their neighbors; they understand their *distance* in terms of capability and compatibility.
*   **Routing as Gradient Descent:** Tasks "flow" through the network towards the nodes best suited to execute them (minimized geometric distance), similar to how gravity pulls water downhill.
*   **Mitosis:** Tasks that are too large for a single node automatically split (undergo mitosis) and disperse their shards across the manifold.

## 🏗 System Architecture

Manifold is built on three pillars: **Geode** (Routing), **Entangle** (VM), and **Nexus** (Consensus).

### 1. Geode: Geometric Routing & Discovery

<p align="center">
  <img src="assets/geode_metric_field.gif" width="45%" />
  <img src="assets/geode_dynamic.gif" width="45%" />
</p>

*   **Feature Vectors:** Every node maintains a vector `[Compute, Memory, Bandwidth]` representing its capabilities.
*   **Minkowski Distance:** We use a weighted Minkowski metric ($p=3$) to calculate the "distance" between a task's requirements and a node's state.
*   **Load Distortion:** The metric is dynamically distorted by the node's current load. A "close" (perfect match) node becomes "far" if it is overloaded, naturally repelling traffic.
*   **Small World Topology:** Nodes self-organize using a Kleinberg-inspired model, maintaining a mix of local ( geometrically similar) and long-range (random shortcut) connections to ensure efficient routing across the cluster.

### 2. Entangle: The Distributed Virtual Machine
Manifold runs a custom stack-based VM ("Entangle") designed for distributed execution.
*   **Micro-Kernels:** Tasks are small assembly programs.
*   **Distributed Shared Memory (DSM):** The VM supports instructions like `LOAD_GLOBAL` and `STORE_GLOBAL` which transparently access a cluster-wide key-value store.
*   **Task Mitosis:** The `parallel_for` task subtype allows the system to automatically break a loop into shards and dispatch them to the top-k geometrically closest neighbors.

### 3. Nexus: Atomic Consensus
For state consistency (e.g., modifying shared counters), Manifold implements a lightweight single-decree Paxos.
*   **`PROPOSE_GLOBAL`:** A VM instruction that attempts an atomic Compare-And-Swap (CAS) on a global variable.
*   Nodes act as Proposers and Acceptors to ensure linearizability of updates across the distributed store.

## 🚀 Getting Started

### Prerequisites
*   Python 3.7+
*   No external dependencies (Standard Library only).

### Installation
Clone the repository:
```bash
git clone https://github.com/Concode0/manifold.git
cd manifold
```

### Configuration
Edit `config.py` to tune the cluster parameters:
```python
NODE_COUNT = 16          # Size of the cluster
TASK_SPLIT_COUNT = 8     # Shards per task
ROUTING_TOP_K = 3        # Stochastic routing factor
```

### Running the Cluster
Launch the distributed system. This starts `NODE_COUNT` processes, initiating the bootstrap and discovery phase.
```bash
python launcher.py
```
*   **Bootstrap:** Node 9001 acts as the seed.
*   **Discovery:** Subsequent nodes join via 9001 and gossip to find peers.
*   **Logs:** You will see aggregated logs from all 16 nodes in your terminal.

### Running a Workload: "The Migrating Collatz"
Run the client to inject a computational task into the manifold.
```bash
python client.py
```
**What happens?**
1.  **Submission:** The client sends a `parallel_for` task (Range 100-1100) to a random node.
2.  **Mitosis:** That node splits the task into `TASK_SPLIT_COUNT` shards.
3.  **Migration:** Shards are routed to the "best" neighbors based on their feature vectors.
4.  **Execution:** Nodes execute the Collatz Conjecture algorithm on their assigned range.
5.  **Aggregation:** Results flow back upstream to the client.

## 🧠 Code Structure

*   `node.py`: The core OS kernel. Handles networking, gossip, routing, and task management.
*   `vm.py`: The "Entangle" Virtual Machine implementation.
*   `launcher.py`: Orchestration tool to spawn the cluster.
*   `client.py`: User-space CLI for submitting jobs.
*   `config.py`: Centralized configuration.

## 🔮 Future Direction
*   **Heterogeneous Simulation:** Currently, feature vectors are random. We plan to simulate distinct node classes (e.g., "GPU Nodes", "Storage Nodes").
*   **True P2P:** Removing the reliance on a single bootstrap node for initial discovery.
*   **Advanced Assembly:** Expanding the VM instruction set for Turing-complete distributed algorithms.

## ⚠️ Disclaimer & Limitations

**This project is a Proof of Concept (PoC) for research purposes only.**

Manifold demonstrates high-level concepts in distributed operating systems and is **NOT** intended for production use. Please be aware of the following limitations:

* **Security (No Auth/Encryption):** The system currently operates over raw TCP sockets without SSL/TLS or any form of authentication.
* **Remote Code Execution:** By design, Manifold nodes execute arbitrary assembly code received from the network. **Do not run this on public networks** or open ports to the internet.
* **Data Persistence:** The Distributed Shared Memory (DSM) is volatile and resides in-memory. All data is lost when nodes shut down.
* **Fault Tolerance:** While it implements basic failure detection, the current Paxos implementation is a simplified single-decree model and may not handle complex partition scenarios (split-brain) robustly.

---
*Created for the purpose of exploring geometric routing in heterogeneous computing environments.*