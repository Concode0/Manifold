import subprocess
import os
import time

def run_benchmarks(num_runs=10, delay_between_runs=5):
    # We store results in repro/benchmark_runs
    runs_dir = os.path.join("repro", "benchmark_runs")
    if not os.path.exists(runs_dir):
        os.makedirs(runs_dir)
    
    files_to_track = [
        "benchmark_suite_a_hete.csv",
        "benchmark_suite_a_homo.csv",
        "benchmark_suite_b.csv",
        "benchmark_suite_c.csv",
        "benchmark_suite_d.csv",
        "benchmark_suite_e_1000.csv",
        "benchmark_suite_e_5000.csv"
    ]
    
    # Path to the benchmark script
    benchmark_script = os.path.join("repro", "benchmark.exs")
    
    for i in range(1, num_runs + 1):
        print(f"Starting Run {i}...")
        
        success = False
        max_retries = 3
        retry_count = 0
        
        while not success and retry_count < max_retries:
            try:
                # Run mix benchmark from project root
                subprocess.run(["mix", "run", benchmark_script], check=True, capture_output=True)
                success = True
            except subprocess.CalledProcessError as e:
                retry_count += 1
                print(f"Error in Run {i} (Attempt {retry_count}/{max_retries}): {e.stderr.decode()}")
                if retry_count < max_retries:
                    print(f"Retrying in {delay_between_runs * 2} seconds (waiting for TCP/Port cleanup)...")
                    time.sleep(delay_between_runs * 2)
                else:
                    print(f"Failed Run {i} after {max_retries} attempts. Skipping.")
        
        if success:
            for filename in files_to_track:
                # benchmark.exs saves CSVs in the current working directory (project root)
                if os.path.exists(filename):
                    new_name = os.path.join(runs_dir, f"{filename.replace('.csv', '')}_{i}.csv")
                    os.rename(filename, new_name)
            print(f"Run {i} complete.")
        
        if i < num_runs:
            print(f"Waiting {delay_between_runs} seconds before next run...")
            time.sleep(delay_between_runs)

if __name__ == "__main__":
    # Ensure we are in the project root if running directly
    # But usually this is run as python3 repro/run_benchmarks.py from root
    run_benchmarks(num_runs=10, delay_between_runs=10)
