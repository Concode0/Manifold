#!/usr/bin/env bash
# Scenario runner: launches cluster, runs 3 scenarios, collects logs.
set -euo pipefail

cd "$(dirname "$0")/.."

LOG_DIR="logs"
mkdir -p "$LOG_DIR"

echo "========== Phase 0: Build & Launch Cluster =========="
docker compose down -v 2>/dev/null || true
docker compose build --quiet
docker compose up -d

echo "Waiting 10s for cluster to converge..."
sleep 10

echo "Cluster status:"
docker compose ps

echo ""
echo "========== Scenario 1: Oversized Task (exceeds all node capacity) =========="
echo "Injecting a task requiring comp=20, mem=20, net=20 (no node can satisfy)..."
docker compose exec -T node_01 python3 -c "print('python3 not available')" 2>/dev/null || true
# Inject directly via host using the exposed port mapping — but we use internal network.
# We'll use a temporary injector container on the same network.
docker run --rm --network basin_basin_net --name injector_s1 \
    python:3.12-alpine python3 -c "
import socket, json, uuid, time
task = {'uuid': str(uuid.uuid4()), 'requirement': [0,20,20,0,20,0,0,0], 'mass': 2.0, 'hop_count': 0, 'split_depth': 0}
pkt = {'type': 'TASK_MIGRATE', 'sender_id': 'injector', 'sender_addr': '0.0.0.0:0', 'task_payload': task}
s = socket.create_connection(('node_01', 8001), timeout=3)
s.sendall((json.dumps(pkt) + '\n').encode())
s.close()
print(f'Injected oversized task {task[\"uuid\"][:8]}')
"
echo "Scenario 1 running for 15s..."
sleep 15

echo ""
echo "========== Scenario 2: Single Task Delivery & Execution =========="
echo "Injecting one normal task into node_03..."
docker run --rm --network basin_basin_net \
    python:3.12-alpine python3 -c "
import socket, json, uuid
task = {'uuid': str(uuid.uuid4()), 'requirement': [0,3,2,0,1,0,0,0], 'mass': 1.0, 'hop_count': 0, 'split_depth': 0}
pkt = {'type': 'TASK_MIGRATE', 'sender_id': 'injector', 'sender_addr': '0.0.0.0:0', 'task_payload': task}
s = socket.create_connection(('node_03', 8001), timeout=3)
s.sendall((json.dumps(pkt) + '\n').encode())
s.close()
print(f'Injected single task {task[\"uuid\"][:8]}')
"
echo "Scenario 2 running for 10s..."
sleep 10

echo ""
echo "========== Scenario 3: Concurrent Multi-Task Organic Interaction =========="
echo "Injecting 15 tasks across multiple nodes simultaneously..."
docker run --rm --network basin_basin_net \
    python:3.12-alpine python3 -c "
import socket, json, uuid, time, threading

def inject(target, comp, mem, net, mass=1.0):
    task = {'uuid': str(uuid.uuid4()), 'requirement': [0,comp,mem,0,net,0,0,0], 'mass': mass, 'hop_count': 0, 'split_depth': 0}
    pkt = {'type': 'TASK_MIGRATE', 'sender_id': 'injector', 'sender_addr': '0.0.0.0:0', 'task_payload': task}
    try:
        s = socket.create_connection((target, 8001), timeout=3)
        s.sendall((json.dumps(pkt) + '\n').encode())
        s.close()
        print(f'  -> {target}: task {task[\"uuid\"][:8]} (c={comp},m={mem},n={net})')
    except Exception as e:
        print(f'  ERR {target}: {e}')

targets = [
    ('node_01', 4, 2, 1.5), ('node_02', 3, 3, 2), ('node_03', 5, 1, 3),
    ('node_04', 2, 4, 1), ('node_05', 6, 2, 2), ('node_06', 3, 1, 4),
    ('node_01', 4, 3, 2), ('node_03', 2, 2, 2), ('node_05', 5, 3, 1),
    ('node_07', 3, 2, 3), ('node_08', 4, 2, 2), ('node_02', 6, 1, 1.5),
    ('node_04', 3, 3, 2), ('node_06', 4, 2, 3), ('node_08', 2, 3, 2),
]
threads = []
for target, c, m, n in targets:
    t = threading.Thread(target=inject, args=(target, c, m, n))
    threads.append(t)
    t.start()
for t in threads:
    t.join()
print('All 15 tasks injected.')
"
echo "Scenario 3 running for 25s..."
sleep 25

echo ""
echo "========== Collecting Logs =========="
for i in $(seq -w 1 8); do
    docker logs "node_0${i#0}" > "$LOG_DIR/node_0${i#0}.log" 2>&1
done

# Merge per-node logs into a single time-sorted file (with verification).
uv run python tools/merge_logs.py -o "$LOG_DIR/cluster_merged.jsonl"
echo "Logs collected in $LOG_DIR/"

echo ""
echo "========== Stopping Cluster =========="
docker compose down
echo "Done."
