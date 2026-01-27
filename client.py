import asyncio
import json
import argparse
import time
import copy
import config

import zlib

def stable_hash(s: str) -> int:
    return zlib.adler32(s.encode())

# Global future to signal when the result is received
result_future = None

async def result_listener(reader, writer):
    global result_future
    try:
        data = await reader.read()
        message = data.decode()
        if message:
            packet = json.loads(message)
            if packet.get('type') == 'result':
                print(f"\n\033[32m[Client]\033[0m RESULT RECEIVED!")
                print(f"Task ID: {packet.get('original_id')}")
                print(f"Data: {packet.get('result')}")
                
                if result_future and not result_future.done():
                    result_future.set_result(packet.get('result'))
                    
    except Exception as e:
        print(f"Listener Error: {e}")
    finally:
        writer.close()

async def run_client(target_port, listen_port):
    global result_future
    result_future = asyncio.get_running_loop().create_future()
    
    # 1. Start Listener Server
    server = await asyncio.start_server(result_listener, '127.0.0.1', listen_port)
    print(f"\033[36m[Client]\033[0m Listening for results on port {listen_port}...")

    # --- TASK: THE MIGRATING COLLATZ ---
    # This task calculates the stopping time for Collatz sequences in a distributed range.
    # The 'parallel_for' subtype will cause the Manifold nodes to split (mitosis) the range
    # and migrate shards to other nodes based on load and feature geometry.
    
    collatz_program = [
        # Setup: Stack has [Start, End] pushed by VM context injection
        # We iterate from Start to End-1
        
        # Initialize Loop Counter (i = Start)
        ['LOAD', 0],           # Stack: [Start]
        
        # --- Main Loop Start (Label 1) ---
        ['DUP'],               # Stack: [i, i]
        ['LOAD', 1],           # Stack: [i, i, End]
        ['SUB'],               # Stack: [i, i - End]
        ['JZ', 20],            # If i == End, Jump to Exit (Label 20)
        
        # Collatz Logic for 'i'
        ['DUP'],               # Stack: [i, i]
        ['PUSH', 0],           # Stack: [i, i, Steps=0]
        
        # --- Collatz Inner Loop (Label 6) ---
        ['SWAP'],              # Stack: [i, Steps, n=i] (simulated swap, actually need rotate)
        # VM doesn't have SWAP/ROT yet? Let's implement Collatz for just 'n' and print (n, steps)
        # Simplified: We just process ONE number 'Start' for now per shard?
        # No, let's implement the loop properly.
        # Since VM is simple, let's make the shard granularity small (1 item per shard) or 
        # just compute for the 'Start' value to keep assembly simple for this PoC.
        
        # NEW PLAN: Simple VM Assembly is hard. 
        # Let's just compute Collatz for the 'Start' value of the shard.
        # If shard size is 1, we get full coverage.
        
        ['POP'],               # Clean stack
        ['LOAD', 0],           # Stack: [n=Start]
        ['DUP'],               # Stack: [n, original_n]
        
        ['PUSH', 0],           # Stack: [n, original_n, steps=0]
        
        # Label 4: Inner Loop Start
        ['PUSH', 1],           # ...
        ['ADD'],               # Increment Steps. Stack: [n, original_n, steps+1]
        
        # Check if n == 1
        ['ROT3'],              # Stack: [steps, n, original_n] -> Wait, VM needs ROT3
    ]
    
    # RE-WRITING ASSEMBLY FOR SIMPLE STACK MACHINE WITHOUT ROT/SWAP
    # We will compute Collatz for the number at Memory[0] (The Start of the range)
    # And return (Number, Steps)
    
    collatz_program_simple = [
        # Init: Mem[2] = CurrentN, Mem[3] = Steps
        ['LOAD', 0],           # 0: [n]
        ['STORE', 2],          # 1: Mem[2] = n
        ['PUSH', 0],           # 2: [0]
        ['STORE', 3],          # 3: Mem[3] = 0 (Steps)
        
        # --- Label 4: Loop Start ---
        ['LOAD', 2],           # 4: [n]
        ['PUSH', 1],           # 5: [n, 1]
        ['SUB'],               # 6: [n-1]
        ['JZ', 28],            # 7: If n==1, Jump to Done (28)
        
        # Increment Steps
        ['LOAD', 3],           # 8: [steps]
        ['PUSH', 1],           # 9: [steps, 1]
        ['ADD'],               # 10: [steps+1]
        ['STORE', 3],          # 11: Mem[3]++
        
        # Check Parity
        ['LOAD', 2],           # 12: [n]
        ['PUSH', 2],           # 13: [n, 2]
        ['MOD'],               # 14: [rem]
        ['JZ', 23],            # 15: If rem==0, Jump to Even (23)
        
        # --- Odd Logic (3n+1) ---
        ['LOAD', 2],           # 16: [n]
        ['PUSH', 3],           # 17: [n, 3]
        ['MUL'],               # 18: [3n]
        ['PUSH', 1],           # 19: [3n, 1]
        ['ADD'],               # 20: [3n+1]
        ['STORE', 2],          # 21: Mem[2] = 3n+1
        ['JMP', 4],            # 22: Loop
        
        # --- Even Logic (n/2) --- (Target of 15)
        ['LOAD', 2],           # 23: [n]
        ['PUSH', 2],           # 24: [n, 2]
        ['DIV'],               # 25: [n/2]
        ['STORE', 2],          # 26: Mem[2] = n/2
        ['JMP', 4],            # 27: Loop
        
        # --- Done --- (Target of 7)
        ['LOAD', 0],           # 28: [OriginalN]
        ['PRINT'],             # 29: Output OriginalN
        ['LOAD', 3],           # 30: [Steps]
        ['PRINT'],             # 31: Output Steps
        ['HALT']               # 32
    ]

    migrating_task = {
        "type": "task",
        "payload": {
            "id": f"Collatz_{int(time.time())}",
            "subtype": "parallel_for",
            "effort": 20.0, # High effort to encourage splitting
            "req": [0.5, 0.5, 0.5],
            "start": 100,
            "end": 1100, 
            "program": collatz_program_simple,
            "return_addr": ["127.0.0.1", listen_port] 
        }
    }

    # helper to inject and wait
    async def run_stage(name, task_dict):
        global result_future
        print(f"\n\033[36m[Stage]\033[0m {name}...")
        try:
            reader, writer = await asyncio.open_connection('127.0.0.1', target_port)
            writer.write(json.dumps(task_dict).encode())
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            
            res = await asyncio.wait_for(result_future, 25.0)
            result_future = asyncio.get_running_loop().create_future()
            return res
        except Exception as e:
            print(f"Error in {name}: {e}")
            return None

    # EXECUTION
    print(f"\n\033[36m[Client]\033[0m Submitting Migrating Collatz Task (Range 100-150)...")
    await run_stage("MIGRATION", migrating_task)
    
    server.close()
    await server.wait_closed()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", type=int, default=9001, help="Target Node Port")
    parser.add_argument("--listen", type=int, default=9000, help="Client Listen Port")
    args = parser.parse_args()
    
    try:
        asyncio.run(run_client(args.node, args.listen))
    except KeyboardInterrupt:
        print("\nClient Exit.")