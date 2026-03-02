import subprocess
import sys
import time
import os
import threading
import config

def stream_logs(process, prefix):
    """Reads stdout from a subprocess and prints it with a colored prefix."""
    try:
        for line in iter(process.stdout.readline, b''):
            decoded_line = line.decode().strip()
            if decoded_line:
                print(f"{prefix} {decoded_line}")
    except Exception as e:
        print(f"{prefix} \033[31mLog Error: {e}\033[0m")

def launch_nodes():
    print(f"\033[36m[System]\033[0m Launching {config.NODE_COUNT} Manifold Nodes...")
    
    processes = []
    current_dir = os.getcwd()
    bootstrap_addr = None

    for i in range(config.NODE_COUNT):
        my_port = config.BASE_PORT + i
        node_script = os.path.join(current_dir, "node.py")
        
        # Use -u for unbuffered output to see logs in real-time
        cmd = [sys.executable, "-u", node_script, "--port", str(my_port), "--cap", str(config.DEFAULT_CAPACITY)]
        
        if i == 0:
            bootstrap_addr = f"127.0.0.1:{my_port}"
        else:
            # All subsequent nodes join via the first one (Bootstrap)
            cmd.extend(["--bootstrap", bootstrap_addr])

        # Launch process with pipes
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        processes.append(proc)
        
        # Create a colored prefix for this node
        # Cyclic colors for better readability
        colors = [31, 32, 33, 34, 35, 36, 91, 92, 93, 94, 95, 96]
        color_code = colors[i % len(colors)]
        prefix = f"\033[{color_code}m[Node {my_port}]\033[0m"
        
        # Start a daemon thread to consume output
        t = threading.Thread(target=stream_logs, args=(proc, prefix), daemon=True)
        t.start()
        
        # Stagger slightly to allow bootstrap to start listening
        if i == 0:
            time.sleep(1.0)
        else:
            time.sleep(0.1)

    print(f"\n\033[32m[Success]\033[0m {config.NODE_COUNT} Nodes Online. Aggregating logs below...")
    print("\033[90m(Press Ctrl+C to terminate the cluster)\033[0m\n")
    
    try:
        # Keep the main thread alive to monitor processes
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n\033[31m[System]\033[0m Shutting down cluster...")
        for p in processes:
            p.terminate()
        sys.exit(0)

if __name__ == "__main__":
    launch_nodes()