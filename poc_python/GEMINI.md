# Manifold: The Geometric Distributed OS

Manifold is a distributed system simulation that demonstrates advanced concepts in distributed computing, including geometric routing, task mitosis (splitting), distributed shared memory (DSM), and consensus (Paxos). It integrates a custom stack-based Virtual Machine (Entangle) with a geometric routing layer (Geode).

## Project Overview

*   **Core Concept:** A "Geometric Distributed OS" where nodes have feature vectors and route tasks based on a "geometric distance" metric that balances feature affinity and node load.
*   **Key Features:**
    *   **Geometric Routing:** Uses a Minkowski metric with load distortion to route tasks to the most suitable nodes.
    *   **Task Mitosis:** Automatic splitting of parallelizable tasks (`parallel_for`) into shards distributed across the cluster.
    *   **Distributed Shared Memory (DSM):** Global key-value store accessible by VM instructions (`LOAD_GLOBAL`, `STORE_GLOBAL`).
    *   **Paxos Consensus:** Implements single-decree Paxos for atomic Compare-And-Swap operations (`PROPOSE_GLOBAL`).
    *   **Fault Tolerance:** Watchdog mechanism to retry failed or timed-out task shards.

## Architecture

The system consists of a cluster of **Manifold Nodes** and **Clients** that submit jobs.

### Components

*   **`node.py` (ManifoldNode):** The main server process.
    *   Maintains a "Small World" network topology.
    *   Runs an `asyncio` event loop for networking, gossip, and task processing.
    *   Executes VM programs (synchronously or asynchronously).
    *   Manages a Ledger for tracking split jobs and aggregating results.
*   **`vm.py` (VirtualMachine):** A simple stack-based virtual machine.
    *   Supports basic arithmetic, flow control (`JMP`, `JZ`), and system calls.
    *   Extended with distributed primitives: `STORE_GLOBAL`, `LOAD_GLOBAL`, `PROPOSE_GLOBAL`.
*   **`client.py`:** A test client that demonstrates a workflow.
    *   Submits a sequence of tasks: "Seed" (initialize DSM), "Heist" (parallel attack on DSM), and "Audit" (verify consistency).
    *   Listens for asynchronous results on a callback port.
*   **`launcher.py`:** Orchestration script.
    *   Launches a cluster of nodes (default: 4) with pre-configured peering (ring + shortcuts).
    *   On macOS (`darwin`), opens separate Terminal windows for each node.

## Usage

### Prerequisites
*   Python 3.7+
*   No external dependencies (uses standard library `asyncio`, `json`, `subprocess`, etc.).

### Running the Cluster
1.  **Launch the Nodes:**
    ```bash
    python launcher.py
    ```
    *   This will start 4 nodes listening on ports 9001-9004.
    *   On macOS, look for new Terminal windows. On other OSs, they run in the background.

2.  **Run the Client:**
    ```bash
    python client.py
    ```
    *   The client listens on port 9000.
    *   It connects to a node (default 9001) to submit tasks.
    *   Observe the "Heist" logic where multiple shards attempt to modify the `vault` variable concurrently using Paxos.

### Key Commands / Operations
*   **Nodes:** `python node.py --port <PORT> --peers <P1,P2...>`
*   **Client:** `python client.py --node <TARGET_PORT> --listen <CLIENT_PORT>`

## Code Structure

*   **Networking:** Pure TCP sockets using `asyncio.start_server` and `open_connection`.
*   **Protocol:** JSON-based packet format (`type`, `payload`, `hops`, etc.).
*   **VM Instruction Set:**
    *   Standard: `PUSH`, `POP`, `ADD`, `SUB`, `PRINT`, `HALT`, `JMP`, `JZ`...
    *   Distributed:
        *   `STORE_GLOBAL`: Write to DSM (Async).
        *   `LOAD_GLOBAL`: Read from DSM (Async, waits for response).
        *   `PROPOSE_GLOBAL`: Atomic CAS via Paxos.

## Development Status
*   **Prototype:** This is a Proof of Concept (PoC) implementation.
*   **Simulated Latency:** Nodes are local, but architecture treats them as remote.
*   **Security:** None. No authentication or encryption.
