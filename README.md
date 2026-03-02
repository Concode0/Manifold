# Manifold: The Geometric Distributed OS (Elixir/Rust Research Core)

Manifold is a research prototype of a distributed operating system that leverages geometric principles (Field-based Gradient Routing) to manage heterogeneity and scale.

## Architecture

This core implementation utilizes a hybrid architecture:
- **Elixir (OTP):** Manages the distributed kernel, including Gossip protocols, Small World topology maintenance, and Raft consensus.
- **Rust (NIFs):** Provides a high-performance, deterministic execution engine (Entangle VM) and a static task effort estimator.

### Key Research Features
- **Geometric Scheduling:** Nodes are mapped into a Riemannian manifold based on their feature vectors (Compute, Memory, Trust). Task routing is performed using gradient descent in the metric space.
- **Task Mitosis:** Automatic splitting of large tasks into deterministic shards based on compile-time effort estimation.
- **Raft DSM:** A strongly consistent, replicated Distributed Shared Memory (DSM) for global state management.
- **Small World Topology:** Self-organizing network links that balance local feature affinity with long-range random shortcuts.

## Prerequisites
- Elixir 1.15+
- Erlang/OTP 26+
- Rust 1.70+
- `mix` (Elixir build tool)

## Quick Start

### 1. Compile the Project
Fetches dependencies and compiles the Rust NIF:
```bash
mix deps.get && mix compile
```

### 2. Run the Research Simulation
Launches a multi-node cluster, interconnects them, and executes a parallelized task:
```bash
mix run simulator.exs
```

### 3. Run Consensus Tests
Verify the Raft-backed Distributed Shared Memory:
```bash
mix run test_dsm.exs
```

## Project Structure
- `lib/manifold_engine/`: Core Elixir modules (Networking, Routing, Mitosis, etc.)
- `native/manifold_rust/`: Rust implementation of the VM and distance metrics.
- `simulator.exs`: The main research simulation environment.
- `poc_python/`: Original Python Proof of Concept.

## License
MIT
