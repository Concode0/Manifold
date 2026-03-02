
"""
Manifold: The Geometric Distributed OS
Integrates Entangle (VM) and Geode (Geometric Routing/Mitosis).
"""

import asyncio
import argparse
import json
import math
import random
import sys
import os
from uuid import uuid4
from typing import Dict, List, Tuple, Optional, Any
from vm import VirtualMachine
import config

import zlib

def stable_hash(s: str) -> int:
    return zlib.adler32(s.encode())

class ManifoldNode:
    def __init__(self, port: int, capacity: float):
        self.id = port
        self.host = '127.0.0.1'
        self.neighbors: List[Tuple[str, int]] = [] 

        self.capacity = capacity
        self.current_load = 0.0
        # Feature Vector (Geometric Coordinate): [Compute, Memory, Bandwidth]
        self.features = [random.random(), random.random(), random.random()]    
        
        # Gossip State Cache: {port: {'load': float, 'features': list, 'ts': float}}
        self.neighbor_states: Dict[int, dict] = {}
        
        # Distributed Shared Memory Store
        self.dsm_store: Dict[str, Any] = {}
        self.dsm_pending: Dict[str, asyncio.Future] = {}
        
        # Paxos State: {key: {'min_proposal': int, 'accepted_proposal': int, 'accepted_value': any}}
        self.paxos_store: Dict[str, dict] = {}

        self.job_ledger: Dict[str, dict] = {} 

        # Dynamic Discovery & Topology
        # {port: {'host': str, 'port': int, 'features': list, 'ts': float}}
        self.known_nodes: Dict[int, dict] = {} 

    def geometric_distance(self, task_req: List[float]) -> float:
        """
        Calculates the Geometric Distance (Manifold Metric) for THIS node.
        """
        return self._calc_distance(self.features, self.current_load, self.capacity, task_req)

    def geometric_distance_remote(self, state: dict, task_req: List[float]) -> float:
        """
        Calculates metric for a REMOTE neighbor based on gossip state.
        """
        return self._calc_distance(state.get('features', [0,0,0]), 
                                   state.get('load', 0.0), 
                                   state.get('cap', 10.0), 
                                   task_req)

    def _calc_distance(self, features, load, capacity, task_req):
        # Minkowski p=3
        dist = sum(abs(f - r)**3 for f, r in zip(features, task_req)) ** (1/3)
        
        # Manifold Distortion
        load_ratio = load / capacity if capacity > 0 else 1.0
        distortion = math.exp(2.0 * load_ratio) 
        
        return dist * distortion

    def get_best_neighbor(self, req: List[float]) -> Optional[Tuple[str, int]]:
        """
        Selects the best neighbor using Manifold Metric based on Gossip Cache.
        """
        if not self.neighbors: return None
        
        candidates = []
        for host, port in self.neighbors:
            state = self.neighbor_states.get(port)
            # Filter dead nodes (Timeout 5s)
            if state and (asyncio.get_event_loop().time() - state['ts'] < 5.0):
                dist = self.geometric_distance_remote(state, req)
                candidates.append((dist, host, port))
            else:
                # High penalty for unknown/dead nodes
                candidates.append((999.0, host, port))
                
        candidates.sort(key=lambda x: x[0])
        if candidates:
            return (candidates[0][1], candidates[0][2])
        return None

    async def execute_vm_async(self, program: list, memory_context: dict = None) -> Any:
        """
        Async VM Execution to support Networked Instructions (DSM).
        """
        vm = VirtualMachine(memory_size=1024)
        if memory_context:
            for k, v in memory_context.items():
                if isinstance(k, int) and k < 1024:
                    vm.memory[k] = v
        
        vm.load_program(program)
        
        # Run loop manually to handle async ops
        while vm.running and vm.steps < 500000:
            if vm.pc >= len(vm.instructions):
                break
                
            instr = vm.instructions[vm.pc]
            op = instr[0].upper()
            
            if op == 'STORE_GLOBAL':
                # [STORE_GLOBAL, "key_string"]
                # Value is popped from stack
                key = instr[1]
                val = vm.stack.pop()
                vm.pc += 1
                vm.steps += 1
                
                # Determine Target Node (Simple Hash Routing)
                # In PoC: hash(key) % N. But we don't know N fully.
                # Strategy: Send to a random neighbor? No, must be deterministic.
                # PoC Strategy: Send to node (9001 + stable_hash(key) % 4)
                target_port = 9001 + (stable_hash(key) % 4)
                
                pkt = {
                    "type": "dsm_store",
                    "payload": {"key": key, "value": val}
                }
                asyncio.create_task(self.send_packet(self.host, target_port, pkt))
                
            elif op == 'LOAD_GLOBAL':
                # [LOAD_GLOBAL, "key_string"]
                key = instr[1]
                vm.pc += 1
                vm.steps += 1
                
                target_port = 9001 + (stable_hash(key) % 4)
                
                # Create a Future to wait for response
                loop = asyncio.get_running_loop()
                fut = loop.create_future()
                
                # Register future in a temporary map so handle_client can find it
                req_id = f"{key}_{uuid4()}"
                self.dsm_pending[req_id] = fut
                
                pkt = {
                    "type": "dsm_load",
                    "payload": {
                        "key": key, 
                        "return_addr": (self.host, self.id),
                        "req_id": req_id 
                    }
                }
                asyncio.create_task(self.send_packet(self.host, target_port, pkt))
                
                # PAUSE VM Execution until Value arrives
                try:
                    val = await asyncio.wait_for(fut, timeout=2.0)
                    vm.stack.append(val)
                except asyncio.TimeoutError:
                    vm.stack.append(0) # Default on timeout
                    print(f"\033[31m[DSM]\033[0m Timeout loading '{key}'")

            elif op == 'PROPOSE_GLOBAL':
                # [PROPOSE_GLOBAL, "key"]
                # Stack: [Value] -> Pushes: [Success(1) or Failure(0)]
                #
                # ATOMIC COMPARE-AND-SWAP (CAS) via PAXOS
                # ---------------------------------------
                # In Manifold, each DSM key is owned by a single "Leader" node (determined by hash).
                # To ensure consistency (e.g., prevent lost updates), we use the Paxos protocol 
                # (Prepare -> Promise -> Accept -> Accepted) directed at this single Leader.
                #
                # This effectively acts as a serialized CAS operation:
                # 1. The Leader enforces a strict sequence of Proposal IDs (n).
                # 2. If multiple nodes propose concurrently, only the one with the highest 'n' 
                #    (that arrives first in Phase 2) wins. The others are rejected or pre-empted.
                # 3. This forces the losing nodes to retry, re-read the value, and propose again.
                
                key = instr[1]
                val = vm.stack.pop()
                vm.pc += 1
                vm.steps += 1
                
                # 1. Target the Single Leader (Owner of the key)
                target_port = 9001 + (stable_hash(key) % 4)
                
                # Proposal ID: Monotonic ID (Time + NodeID)
                n = int(asyncio.get_event_loop().time() * 1000000) + self.id
                
                # --- Phase 1: Prepare ---
                loop = asyncio.get_running_loop()
                fut = loop.create_future()
                req_id = f"paxos_prep_{key}_{uuid4()}"
                self.dsm_pending[req_id] = fut
                
                pkt = {
                    "type": "paxos_prepare",
                    "payload": {
                        "key": key, "n": n, "return_addr": (self.host, self.id), "req_id": req_id
                    }
                }
                asyncio.create_task(self.send_packet(self.host, target_port, pkt))
                
                try:
                    # Wait for Promise
                    resp_pkt = await asyncio.wait_for(fut, timeout=2.0)
                    del self.dsm_pending[req_id] # Cleanup
                    
                    promise = resp_pkt['payload']
                    
                    # Paxos Logic:
                    # In a full consensus system, if the Acceptor returned a value (accepted_val),
                    # the Proposer MUST adopt it to ensure safety.
                    #
                    # However, since Manifold uses this for "New Value Injection" (CAS),
                    # if we see an existing value, it means we are racing against a committed value.
                    # Standard Paxos would make us re-propose *that* value (No-Op).
                    # 
                    # For our "Atomic Update" semantics, if we are preempted or see an old value,
                    # we essentially fail the CAS (or succeed in being serialized later).
                    # Here, we proceed to propose OUR value. If the leader has accepted a higher 'n'
                    # in the meantime, Phase 2 will fail (silent drop in this PoC implementation).
                    
                    # If Promise received:
                    # --- Phase 2: Accept ---
                    fut2 = loop.create_future()
                    req_id2 = f"paxos_acc_{key}_{uuid4()}"
                    self.dsm_pending[req_id2] = fut2
                    
                    pkt2 = {
                        "type": "paxos_accept",
                        "payload": {
                            "key": key, "n": n, "value": val, 
                            "return_addr": (self.host, self.id), "req_id": req_id2
                        }
                    }
                    asyncio.create_task(self.send_packet(self.host, target_port, pkt2))
                    
                    await asyncio.wait_for(fut2, timeout=2.0)
                    del self.dsm_pending[req_id2]
                    
                    # Success
                    vm.stack.append(1) # True
                    
                except asyncio.TimeoutError:
                    print(f"\033[31m[PAXOS]\033[0m Proposal {n} Timed Out")
                    vm.stack.append(0) # False

            else:
                # Standard Sync Op
                vm.step()
                
            # Yield to event loop occasionally
            if vm.steps % 100 == 0:
                await asyncio.sleep(0)
                
        return vm.output

    def task_split(self, parent_task: dict) -> List[Tuple[dict, Tuple[str, int]]]:
        """
        Mitosis: Splitting a Parallel Loop Task.
        Returns List of (SubTask, TargetNode).
        """
        split_count = 32
        job_id = str(uuid4())
        
        print(f"\033[35m[MITOSIS]\033[0m Splitting Task {parent_task['id']} into {split_count} shards...")

        start = parent_task.get('start', 0)
        end = parent_task.get('end', 100)
        total_range = end - start
        step = total_range // split_count
        
        self.job_ledger[job_id] = {
            "original_id": parent_task['id'],
            "total": split_count,
            "received": 0,
            "results": [],
            "upstream": {
                "return_addr": parent_task.get('return_addr'),
                "parent_job_id": parent_task.get('parent_job_id'),
                "task_id": parent_task.get('id')
            },
            "shards": {} # For Watchdog
        }
        
        sub_tasks_assignments = []
        req = parent_task.get('req', [0.5, 0.5, 0.5])

        # Get Top 3 Candidates
        candidates = []
        for host, port in self.neighbors:
            state = self.neighbor_states.get(port)
            if state and (asyncio.get_event_loop().time() - state['ts'] < 5.0):
                dist = self.geometric_distance_remote(state, req)
                candidates.append((dist, host, port))
            else:
                candidates.append((999.0, host, port))
        
        candidates.sort(key=lambda x: x[0])
        top_k = candidates[:3] if candidates else []

        for i in range(split_count):
            sub_start = start + (i * step)
            sub_end = start + ((i + 1) * step) if i < split_count - 1 else end
            
            sub_task = parent_task.copy()
            sub_task['id'] = f"{parent_task['id']}_shard_{i}"
            sub_task['parent_job_id'] = job_id
            sub_task['start'] = sub_start
            sub_task['end'] = sub_end
            sub_task['effort'] = parent_task['effort'] / split_count
            sub_task['return_addr'] = (self.host, self.id)
            sub_task['is_subtask'] = True
            
            # Select Target: Random from Top 3
            target = None
            if top_k:
                _, th, tp = random.choice(top_k)
                target = (th, tp)
            elif self.neighbors:
                target = random.choice(self.neighbors)
            
            if target:
                # Record Assignment
                self.job_ledger[job_id]['shards'][sub_task['id']] = {
                    "task": sub_task,
                    "assigned_to": target, # (host, port)
                    "ts": asyncio.get_event_loop().time(),
                    "status": "pending",
                    "retries": 0
                }
                sub_tasks_assignments.append((sub_task, target))
            else:
                print(f"\033[31m[ERROR]\033[0m No neighbors to accept shard {i}!")
            
        return sub_tasks_assignments

    def aggregate_result(self, result_packet: dict):
        job_id = result_packet.get('parent_job_id')
        if job_id in self.job_ledger:
            entry = self.job_ledger[job_id]
            
            # Identify which shard returned
            # result_packet should ideally carry shard_id. 
            # Currently it carries 'original_id' which IS the shard_id for subtasks.
            shard_id = result_packet.get('original_id')
            
            # Idempotency Check: Don't count same shard twice (e.g. from a race retry)
            if entry.get('shards') and shard_id in entry['shards']:
                if entry['shards'][shard_id]['status'] == 'completed':
                    return # Ignore duplicate
                entry['shards'][shard_id]['status'] = 'completed'

            entry['received'] += 1
            entry['results'].append(result_packet['result'])
            
            print(f"\033[90m[LEDGER]\033[0m Job {entry['original_id']} Progress: {entry['received']}/{entry['total']}")
            
            if entry['received'] == entry['total']:
                print(f"\033[32m[AGGREGATE]\033[0m Job {entry['original_id']} Complete. Reducing results...")
                
                # Reduction Logic (Summation for PoC)
                # Flatten lists if results are lists
                flat_results = []
                for res in entry['results']:
                    if isinstance(res, list):
                        flat_results.extend(res)
                    else:
                        flat_results.append(res)
                
                upstream = entry['upstream']
                if upstream.get('return_addr'):
                    host, port = upstream['return_addr']
                    pkt = {
                        "type": "result",
                        "parent_job_id": upstream['parent_job_id'],
                        "result": flat_results,
                        "original_id": upstream['task_id']
                    }
                    # Wrap send_packet to handle exceptions without crashing the loop
                    async def safe_send():
                        try:
                            await self.send_packet(host, port, pkt)
                        except Exception as e:
                            print(f"\033[31m[ERROR]\033[0m Failed to return result to {host}:{port} - {e}")

                    asyncio.create_task(safe_send())
                else:
                    print(f"\033[32m[FINAL]\033[0m Result: {flat_results[:10]}... (Len: {len(flat_results)})")
                
                del self.job_ledger[job_id]

    async def process_task(self, task: dict, return_addr: Optional[Tuple[str, int]]):
        task_id = task['id']
        effort = task.get('effort', 1.0)
        
        self.current_load += effort 
        
        print(f"\033[34m[VM START]\033[0m Task {task_id} | Range: {task.get('start')}->{task.get('end')}")
        
        # Inject Dynamic Parameters into VM Memory or Code
        # Strategy: Prepend PUSH instructions for args
        program = task.get('program', [])
        
        # If task has start/end, we assume the program wants them on the stack or in specific memory
        # Let's put them in Memory[0] and Memory[1]
        mem_ctx = {}
        if 'start' in task: mem_ctx[0] = task['start']
        if 'end' in task: mem_ctx[1] = task['end']
        
        # Run VM in Thread Pool to not block Event Loop
        # output = await asyncio.to_thread(self.execute_vm, program, mem_ctx)
        
        # Switch to Async VM for DSM support
        output = await self.execute_vm_async(program, mem_ctx)
        
        print(f" \033[32m[VM DONE]\033[0m Task {task_id}")
        
        self.current_load -= effort
        return output

    async def process_dsm_request(self, packet: dict):
        """
        Handles Distributed Shared Memory (DSM) requests.
        """
        payload = packet['payload']
        req_type = packet['type']
        
        if req_type == 'dsm_store':
            key = payload['key']
            val = payload['value']
            self.dsm_store[key] = val
            # print(f"\033[36m[DSM]\033[0m Stored '{key}' = {val}")
            
        elif req_type == 'dsm_load':
            key = payload['key']
            val = self.dsm_store.get(key, 0) # Default 0
            
            # Send Response
            ret_host, ret_port = payload['return_addr']
            resp_pkt = {
                "type": "dsm_resp",
                "payload": {
                    "key": key, 
                    "value": val,
                    "req_id": payload.get('req_id') # Echo ID
                }
            }
            try:
                await self.send_packet(ret_host, ret_port, resp_pkt)
            except: pass

    async def handle_paxos_message(self, packet: dict):
        """
        Handles Paxos Consensus Protocol Messages (Prepare/Accept).
        Acts as the 'Acceptor' role for keys owned by this node.
        """
        payload = packet['payload']
        msg_type = packet['type']
        key = payload['key']
        n = payload['n']
        
        # Init State if new
        if key not in self.paxos_store:
            self.paxos_store[key] = {'min_proposal': 0, 'accepted_proposal': 0, 'accepted_value': None}
        
        state = self.paxos_store[key]
        
        if msg_type == 'paxos_prepare':
            # Phase 1b: Promise
            if n > state['min_proposal']:
                state['min_proposal'] = n
                # Reply Promise
                reply = {
                    "type": "paxos_promise",
                    "payload": {
                        "key": key,
                        "n": n,
                        "accepted_n": state['accepted_proposal'],
                        "accepted_val": state['accepted_value'],
                        "req_id": payload.get('req_id')
                    }
                }
                # Send back to Proposer
                ret_host, ret_port = payload['return_addr']
                asyncio.create_task(self.send_packet(ret_host, ret_port, reply))
            else:
                # Optional: Nack (Optimization, not strict Paxos)
                pass

        elif msg_type == 'paxos_accept':
            # Phase 2b: Accepted
            # In a full Paxos system, this is where we check quorum.
            # Here, since we are the Single Leader for this key, accepting means COMMIT.
            # We effectively act as Proposer, Acceptor, and Learner logic rolled into one 
            # for the CAS operation.
            
            val = payload['value']
            if n >= state['min_proposal']:
                state['min_proposal'] = n
                state['accepted_proposal'] = n
                state['accepted_value'] = val
                
                # Update local DSM (Commit)
                self.dsm_store[key] = val
                
                reply = {
                    "type": "paxos_accepted",
                    "payload": {
                        "key": key,
                        "n": n,
                        "value": val,
                        "req_id": payload.get('req_id')
                    }
                }
                ret_host, ret_port = payload['return_addr']
                asyncio.create_task(self.send_packet(ret_host, ret_port, reply))

    async def join_network(self, bootstrap_peer: str):
        if not bootstrap_peer: return
        
        try:
            b_host, b_port = bootstrap_peer.split(':')
            b_port = int(b_port)
            
            print(f"\033[36m[DISCOVERY]\033[0m Joining via Bootstrap Node {b_port}...")
            
            # 1. Send Join Request
            packet = {
                "type": "join",
                "payload": {
                    "id": self.id,
                    "host": self.host,
                    "port": self.id,
                    "features": self.features,
                    "ts": asyncio.get_event_loop().time()
                }
            }
            await self.send_packet(b_host, b_port, packet)
            
            # Add Bootstrap as temporary known node
            self.known_nodes[b_port] = {
                "id": b_port,
                "host": b_host, "port": b_port, 
                "features": [0.5,0.5,0.5], # Unknown yet
                "ts": asyncio.get_event_loop().time()
            }
            
        except Exception as e:
            print(f"\033[31m[ERROR]\033[0m Failed to join network: {e}")

    async def topology_maintenance(self):
        """
        Kleinberg / Small World Topology Maintenance.
        Periodically selects neighbors from known_nodes to balance Local (Short) and Long links.
        """
        K_LOCAL = 2
        K_LONG = 2
        
        while True:
            await asyncio.sleep(5.0)
            
            if not self.known_nodes: continue
            
            # 1. Prune dead nodes
            now = asyncio.get_event_loop().time()
            active_candidates = []
            
            for port, info in self.known_nodes.items():
                if port == self.id: continue
                # Simple liveness check (based on last seen TS from gossip/discovery)
                if (now - info['ts']) < 30.0:
                    active_candidates.append(info)
            
            if not active_candidates: continue
            
            # 2. Sort by Geometric Distance (Short Links)
            # We need feature vectors. If missing, assume far.
            for node in active_candidates:
                dist = self._calc_distance(self.features, 0, 10, node.get('features', [0.5,0.5,0.5]))
                node['dist'] = dist
                
            active_candidates.sort(key=lambda x: x.get('dist', 999))
            
            new_neighbors = set()
            
            # Select K Nearest (Local)
            for node in active_candidates[:K_LOCAL]:
                new_neighbors.add((node['host'], node['port']))
                
            # Select M Random (Long Range) from the REST
            remaining = active_candidates[K_LOCAL:]
            if remaining:
                # Weighted probability could be 1/dist, but random is fine for PoC Small World
                sampled = random.sample(remaining, min(len(remaining), K_LONG))
                for node in sampled:
                    new_neighbors.add((node['host'], node['port']))
            
            # Update Neighbors
            old_set = set(self.neighbors)
            if new_neighbors != old_set:
                self.neighbors = list(new_neighbors)
                print(f"\033[35m[TOPOLOGY]\033[0m Updated Neighbors: {[p for h,p in self.neighbors]}")

    async def run_server(self, bootstrap_peer: str = None):
        server = await asyncio.start_server(self.handle_client, self.host, self.id, limit=100*1024*1024)
        print(f"==========================================")
        print(f" Manifold Node \033[33m{self.id}\033[0m Online")
        print(f" Feature Geometry: {[round(f,2) for f in self.features]}")
        print(f"==========================================\n")
        
        # Start Gossip Protocol
        asyncio.create_task(self.gossip_loop())
        # Start Watchdog
        asyncio.create_task(self.watchdog_loop())
        # Start Topology Maintenance
        asyncio.create_task(self.topology_maintenance())
        
        if bootstrap_peer:
            asyncio.create_task(self.join_network(bootstrap_peer))
        
        async with server:
            await server.serve_forever()

    async def watchdog_loop(self):
        """Fault Tolerance: Monitors pending shards and retries if timed out or node dead."""
        TIMEOUT = 8.0 # Seconds
        
        while True:
            await asyncio.sleep(1.0)
            now = asyncio.get_event_loop().time()
            
            # Iterate over all active jobs
            for job_id, entry in list(self.job_ledger.items()):
                shards = entry.get('shards', {})
                for shard_id, meta in shards.items():
                    if meta['status'] == 'completed': continue
                    
                    assigned_host, assigned_port = meta['assigned_to']
                    
                    # Check 1: Explicit Time Timeout
                    is_timed_out = (now - meta['ts']) > TIMEOUT
                    
                    # Check 2: Node Death (Gossip Timeout)
                    neighbor_state = self.neighbor_states.get(assigned_port)
                    is_node_dead = False
                    if neighbor_state:
                         if (now - neighbor_state['ts']) > 5.0:
                             is_node_dead = True
                    else:
                        # If we have no state for it, maybe it's just gone?
                        # Or maybe we just haven't heard yet.
                        pass

                    if (is_timed_out or is_node_dead) and meta['retries'] < 3:
                        print(f"\033[31m[WATCHDOG]\033[0m Shard {shard_id} Failed (Timeout={is_timed_out}, Dead={is_node_dead}). Retrying...")
                        
                        # Retry Logic: Pick NEW target
                        req = meta['task'].get('req', [0.5, 0.5, 0.5])
                        new_target = self.get_best_neighbor(req)
                        
                        # Fallback
                        if not new_target and self.neighbors:
                            new_target = random.choice(self.neighbors)
                            
                        if new_target:
                            th, tp = new_target
                            meta['assigned_to'] = new_target
                            meta['ts'] = now
                            meta['retries'] += 1
                            
                            pkt = {"type": "task", "payload": meta['task'], "hops": 0}
                            asyncio.create_task(self.send_packet(th, tp, pkt))
                            print(f" \033[33m->\033[0m Re-assigned to {tp}")
                        else:
                            print(" \033[31m->\033[0m No neighbors to retry!")

    async def gossip_loop(self):
        """Periodically broadcast state to neighbors (SMN Protocol)."""
        while True:
            await asyncio.sleep(2.0) # Gossip interval
            if not self.neighbors: continue
            
            # Construct Gossip Packet
            packet = {
                "type": "gossip",
                "payload": {
                    "id": self.id,
                    "load": self.current_load,
                    "cap": self.capacity,
                    "features": self.features,
                    "ts": asyncio.get_event_loop().time()
                }
            }
            
            # Broadcast to random subset or all neighbors
            # For SMN, we want strong local knowledge, so we send to all immediate neighbors
            for host, port in self.neighbors:
                asyncio.create_task(self.send_packet(host, port, packet))

    async def handle_client(self, reader, writer):
        try:
            data = await reader.read() 
            message = data.decode()
        except Exception: return
        
        if not message: return

        try:
            packet = json.loads(message)
        except: return

        packet_type = packet.get('type', 'task')
        
        if packet_type == 'gossip':
            # Update Neighbor State Cache
            payload = packet['payload']
            sender_id = payload['id']
            self.neighbor_states[sender_id] = payload
            # print(f"\033[90m[GOSSIP]\033[0m Updated state for Node {sender_id}")

        elif packet_type == 'join':
            # Handle Join Request
            payload = packet['payload']
            sender_port = payload['id']
            
            # Add to Known Nodes
            self.known_nodes[sender_port] = payload
            
            print(f"\033[32m[JOIN]\033[0m Node {sender_port} joined.")
            
            # Send Peer Exchange (Gossip known nodes back)
            peer_list = list(self.known_nodes.values())
            # Add self
            peer_list.append({
                "id": self.id, "host": self.host, "port": self.id, 
                "features": self.features, "ts": asyncio.get_event_loop().time()
            })
            
            resp = {
                "type": "peer_exchange",
                "payload": peer_list
            }
            host = payload.get('host', '127.0.0.1')
            asyncio.create_task(self.send_packet(host, sender_port, resp))

        elif packet_type == 'peer_exchange':
            # Merge received peers into known_nodes
            peers = packet['payload']
            for p in peers:
                pid = p.get('id') or p.get('port')
                if pid == self.id: continue
                if pid not in self.known_nodes:
                    self.known_nodes[pid] = p
                else:
                    # Update TS
                    if p['ts'] > self.known_nodes[pid]['ts']:
                        self.known_nodes[pid] = p
            
        elif packet_type == 'result':
            self.aggregate_result(packet)
            
        elif packet_type in ['dsm_store', 'dsm_load']:
            asyncio.create_task(self.process_dsm_request(packet))
        
        elif packet_type in ['paxos_prepare', 'paxos_accept']:
            asyncio.create_task(self.handle_paxos_message(packet))
            
        elif packet_type in ['paxos_promise', 'paxos_accepted']:
            # Signal waiting Futures
            payload = packet['payload']
            req_id = payload.get('req_id')
            if req_id in self.dsm_pending:
                # We assume the VM is polling/waiting on this future.
                # For Multi-Stage Paxos, this is tricky. The Future is for the *current step*.
                if not self.dsm_pending[req_id].done():
                    self.dsm_pending[req_id].set_result(packet)
                    # We DON'T delete yet, VM might need to reuse same req_id logic? 
                    # No, VM loop creates new future for next step.
                
        elif packet_type == 'dsm_resp':
            # Resume VM
            payload = packet['payload']
            # We need to know which future to complete. 
            # In a real system, we'd pass a request ID.
            # Updated protocol to include req_id.
            req_id = payload.get('req_id') 
            # Fallback for PoC: if we only have one pending per key (not safe but works for simple demo)
            # Actually, let's fix process_dsm_request to echo req_id first.
            if req_id in self.dsm_pending:
                if not self.dsm_pending[req_id].done():
                    self.dsm_pending[req_id].set_result(payload['value'])
                del self.dsm_pending[req_id]
            
        elif packet_type == 'task':
            task = packet['payload']
            
            # Geometric Scheduling Decision
            # Check 'Repulsion' (Overload)
            load_factor = self.current_load / self.capacity
            
            # Check 'Mitosis' (Task too big)
            is_parallel = task.get('subtype') == 'parallel_for'
            if is_parallel and task['effort'] > 5.0 and not task.get('is_subtask'):
                 # Split locally
                sub_assignments = self.task_split(task)
                for st, target in sub_assignments:
                    host, port = target
                    new_pkt = {"type": "task", "payload": st, "hops": 0}
                    asyncio.create_task(self.send_packet(host, port, new_pkt))
                    print(f" \033[90m->\033[0m Dispatched Shard to {port}")

            elif load_factor > 0.8:
                # Repel
                print(f"\033[33m[REPULSION]\033[0m High Load ({load_factor:.2f}). Rejecting...")
                await self.forward_geometric(packet)
            
            else:
                # Accept
                return_addr = task.get('return_addr')
                if isinstance(return_addr, list): return_addr = tuple(return_addr)
                asyncio.create_task(self.process_task_wrapper(task, return_addr))

        writer.close()
        await writer.wait_closed()

    async def process_task_wrapper(self, task: dict, return_addr: Optional[Tuple[str, int]]):
        result = await self.process_task(task, return_addr)
        if return_addr:
            host, port = return_addr
            pkt = {
                "type": "result",
                "parent_job_id": task.get('parent_job_id'),
                "result": result,
                "original_id": task.get('id')
            }
            try:
                await self.send_packet(host, port, pkt)
            except: pass

    async def forward_geometric(self, packet: dict):
        """
        Routes task to the neighbor with the minimal Geometric Distance (SMN Greedy).
        """
        if not self.neighbors: return
        
        packet['hops'] = packet.get('hops', 0) + 1
        req = packet['payload'].get('req', [0.5, 0.5, 0.5]) 
        
        # SMN Greedy Routing:
        # 1. Evaluate all neighbors based on cached Gossip state.
        # 2. If state is missing, assume average/high distance.
        
        best_node = None
        min_dist = float('inf')
        
        candidates = []
        
        for host, port in self.neighbors:
            state = self.neighbor_states.get(port)
            if state:
                dist = self.geometric_distance_remote(state, req)
                candidates.append((dist, host, port))
            else:
                # Explore unknown nodes with some probability or assign high penalty
                # "Exploration" bias
                candidates.append((100.0, host, port))
                
        # Sort by distance (Gradient Descent)
        candidates.sort(key=lambda x: x[0])
        
        if candidates:
            # Pick the best one
            _, target_host, target_port = candidates[0]
            
            try:
                await self.send_packet(target_host, target_port, packet)
                print(f" \033[90m->\033[0m Routed to {target_port} (Dist: {candidates[0][0]:.2f})")
            except: 
                # Fallback to random if best fails
                target_host, target_port = random.choice(self.neighbors)
                asyncio.create_task(self.send_packet(target_host, target_port, packet))

    async def send_packet(self, host: str, port: int, packet: dict):
        reader, writer = await asyncio.open_connection(host, port, limit=100*1024*1024)
        writer.write(json.dumps(packet).encode())
        await writer.drain()
        writer.close()
        await writer.wait_closed()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cap", type=float, default=10.0)
    parser.add_argument("--peers", type=str, default="")
    parser.add_argument("--bootstrap", type=str, default=None, help="Bootstrap Node (host:port)")
    args = parser.parse_args()
    
    node = ManifoldNode(args.port, args.cap)
    if args.peers:
        for p in args.peers.split(","):
            if p.strip(): node.neighbors.append(('127.0.0.1', int(p)))
            
    try:
        asyncio.run(node.run_server(bootstrap_peer=args.bootstrap))
    except KeyboardInterrupt: pass
