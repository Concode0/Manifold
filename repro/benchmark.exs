# Manifold Benchmark Suite
# Reordered: A (Routing), B (Mitosis), C (Consensus), D (VM)

defmodule ManifoldEngine.Benchmark.ElixirVM do
  def execute_task(program, start_val, end_val) do
    execute_internal(program, start_val, end_val, %{}, [])
  end

  defp execute_internal([], _start, _end, _mem, stack), do: List.first(stack) || 0.0
  defp execute_internal([instr | rest], start_val, end_val, mem, stack) do
    case instr do
      {:push, v} -> execute_internal(rest, start_val, end_val, mem, [v | stack])
      :add ->
        {b, a, s} = pop2(stack)
        execute_internal(rest, start_val, end_val, mem, [a + b | s])
      :sub ->
        {b, a, s} = pop2(stack)
        execute_internal(rest, start_val, end_val, mem, [a - b | s])
      :mul ->
        {b, a, s} = pop2(stack)
        execute_internal(rest, start_val, end_val, mem, [a * b | s])
      :div ->
        {b, a, s} = pop2(stack)
        val = if b != 0.0, do: a / b, else: 0.0
        execute_internal(rest, start_val, end_val, mem, [val | s])
      {:load, addr} ->
        val = Map.get(mem, addr, 0.0)
        execute_internal(rest, start_val, end_val, mem, [val | stack])
      {:store, addr} ->
        {v, s} = pop1(stack)
        execute_internal(rest, start_val, end_val, Map.put(mem, addr, v), s)
      :get_start -> execute_internal(rest, start_val, end_val, mem, [start_val | stack])
      :get_end -> execute_internal(rest, start_val, end_val, mem, [end_val | stack])
      {:loop, iters, body_len} ->
        {body, remaining} = Enum.split(rest, body_len)
        {final_mem, final_stack} = Enum.reduce(1..iters, {mem, stack}, fn _, {acc_mem, acc_stack} ->
           {res, new_mem} = execute_loop_body(body, start_val, end_val, acc_mem)
           {new_mem, [res | acc_stack]}
        end)
        execute_internal(remaining, start_val, end_val, final_mem, final_stack)
    end
  end

  defp execute_loop_body(body, start, end_val, mem) do
    res = execute_internal(body, start, end_val, mem, [])
    {res, mem}
  end

  defp pop1([v | s]), do: {v, s}
  defp pop1([]), do: {0.0, []}
  defp pop2([b, a | s]), do: {b, a, s}
  defp pop2([b]), do: {b, 0.0, []}
  defp pop2([]), do: {0.0, 0.0, []}
end

defmodule ManifoldEngine.Benchmark.TailLatency do
  @moduledoc """
  Rigorous Tail Latency Benchmark for the Manifold Distributed OS.

  This suite evaluates end-to-end task completion times under concurrent load,
  comparing Manifold's Field-Based Gradient Routing (L3) against the
  Power of Two Choices (P2C) algorithm.
  """

  alias ManifoldEngine.{Router, Node, Application, Task}

  @doc """
  Runs the tail latency benchmark.
  - num_tasks: Total number of tasks to measure (default 1000).
  - target_qps: Injected load in Queries Per Second (default 500).
  """
  def run(num_tasks \\ 1000, target_qps \\ 500, base_port \\ 30000) do
    ports = Enum.map(1..5, fn i -> base_port + i end)
    ManifoldEngine.Benchmark.ClusterHelper.start_cluster(ports)

    # Phase 1: Warm-up
    # Ensures BEAM JIT compilation and Gossip convergence before measurement.
    IO.puts("\n--- [Phase 1: Warming up BEAM VM & Gossip Network] ---")
    Process.sleep(2000)
    warmup(ports, 200)

    # Phase 2: Main Benchmark
    IO.puts("\n--- [Phase 2: Academic Tail Latency Run] ---")
    IO.puts("Target QPS: #{target_qps} | Sample Size: #{num_tasks} tasks\n")

    manifold_stats = measure_latencies(:manifold, ports, num_tasks, target_qps, 30000)
    Process.sleep(3000) # Cooldown period for algorithmic isolation

    p2c_stats = measure_latencies(:p2c, ports, num_tasks, target_qps, 30000)

    # Final Report
    IO.puts("\n=== [Final Tail Latency Report (ms)] ===")
    IO.puts("ALGO     |  p10      |  p25      |  p50      |  p75      |  p90      |  p95      |  p99      | p99.9     |  Max")
    IO.puts("------------------------------------------------------------------------------------------------------------------")
    print_row("Manifold", manifold_stats)
    print_row("P2C", p2c_stats)

    ManifoldEngine.Benchmark.ClusterHelper.stop_all(ports)
    %{manifold: manifold_stats, p2c: p2c_stats}
  end

  # Open-loop load generator with Poisson-like arrivals
  defp measure_latencies(algo, ports, num_tasks, qps, timeout_ms) do
    callback_port = 25006
    {:ok, l} = :gen_tcp.listen(callback_port, [:binary, packet: 4, active: false, reuseaddr: true])

    parent = self()
    # Async result collector to handle out-of-order returns
    collector = spawn(fn -> collector_loop(num_tasks, %{}, parent) end)
    spawn(fn -> accept_loop(l, collector) end)

    program = [{:loop, 1000, 1}, {:push, 1.0}]
    interval_ms = 1000 / qps

    # Dispatch loop
    task_starts = Enum.map(1..num_tasks, fn i ->
      entry_port = Enum.random(ports)
      task_id = "t_#{algo}_#{i}"

      target_port = select_target(algo, entry_port, ports)

      task = %Task{
        id: task_id,
        program: program,
        start: 0.0,
        end: 1.0,
        req: [1.0, 1.0],
        return_addr: {"127.0.0.1", callback_port}
      }

      start_ts = System.monotonic_time(:microsecond)
      send_via_tcp(target_port, task)

      # Throttle dispatch rate to target QPS
      if rem(i, 10) == 0, do: Process.sleep(round(interval_ms * 10))

      {task_id, start_ts}
    end) |> Map.new()

    IO.puts("[#{algo}] Dispatch complete. Collecting samples...")

    # Wait for collector to finish or timeout
    receive do
      {:results, completion_times} ->
        latencies = Enum.map(task_starts, fn {id, start_ts} ->
          case Map.get(completion_times, id) do
            nil -> timeout_ms * 1.0
            end_ts -> (end_ts - start_ts) / 1000.0
          end
        end)
        :gen_tcp.close(l)
        calculate_stats(latencies)
    after timeout_ms + 5000 ->
      :gen_tcp.close(l)
      calculate_stats([timeout_ms * 1.0])
    end
  end

  defp select_target(:manifold, entry_port, _ports) do
    case Router.best_candidates([1.0, 1.0], entry_port, 1) do
      [{peer, _} | _] -> peer.id
      _ -> entry_port
    end
  end

  defp select_target(:p2c, _entry_port, ports) do
    # NON-SIMPLIFIED Capacity-Aware P2C
    [p1, p2] = Enum.take_random(ports, 2)
    s1 = Node.get_state(p1)
    s2 = Node.get_state(p2)
    
    r1 = (s1.current_load + s1.ledger_pressure) / (s1.capacity || 1.0)
    r2 = (s2.current_load + s2.ledger_pressure) / (s2.capacity || 1.0)
    
    if r1 <= r2, do: p1, else: p2
  end

  defp collector_loop(0, times, parent), do: send(parent, {:results, times})
  defp collector_loop(remaining, times, parent) do
    receive do
      {:done, id, ts} -> collector_loop(remaining - 1, Map.put(times, id, ts), parent)
    after 15000 -> send(parent, {:results, times})
    end
  end

  defp accept_loop(l, collector) do
    case :gen_tcp.accept(l) do
      {:ok, s} ->
        spawn(fn ->
          case :gen_tcp.recv(s, 0, 5000) do
            {:ok, data} ->
              ts = System.monotonic_time(:microsecond)
              case :erlang.binary_to_term(data) do
                %{type: "result", payload: %{task_id: id}} -> send(collector, {:done, id, ts})
                _ -> :ok
              end
            _ -> :ok
          end
          :gen_tcp.close(s)
        end)
        accept_loop(l, collector)
      _ -> :ok
    end
  end

  defp warmup(ports, num_tasks) do
    Enum.each(1..num_tasks, fn i ->
      port = Enum.random(ports)
      task = %Task{id: "w_#{i}", program: [{:push, 1.0}], req: [1.0, 1.0]}
      send_via_tcp(port, task)
    end)
    Process.sleep(1000)
  end

  defp calculate_stats(latencies) do
    sorted = Enum.sort(latencies)
    count = length(sorted)

    %{
      p10: Enum.at(sorted, round(count * 0.10) - 1) || 0.0,
      p25: Enum.at(sorted, round(count * 0.25) - 1) || 0.0,
      p50: Enum.at(sorted, round(count * 0.50) - 1) || 0.0,
      p75: Enum.at(sorted, round(count * 0.75) - 1) || 0.0,
      p90: Enum.at(sorted, round(count * 0.90) - 1) || 0.0,
      p95: Enum.at(sorted, round(count * 0.95) - 1) || 0.0,
      p99: Enum.at(sorted, round(count * 0.99) - 1) || 0.0,
      p99_9: Enum.at(sorted, round(count * 0.999) - 1) || 0.0,
      max: List.last(sorted) || 0.0
    }
  end

  defp print_row(name, stats) do
    :io.format("~-8s | ~8.2f | ~8.2f | ~8.2f | ~8.2f | ~8.2f | ~8.2f | ~8.2f | ~8.2f | ~8.2f~n",
      [name, stats.p10, stats.p25, stats.p50, stats.p75, stats.p90, stats.p95, stats.p99, stats.p99_9, stats.max])
  end

  defp send_via_tcp(port, task) do
    spawn(fn ->
      case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: 4, active: false], 1000) do
        {:ok, s} ->
          :gen_tcp.send(s, :erlang.term_to_binary(%{type: "task", payload: task}))
          :gen_tcp.close(s)
        _ -> :error
      end
    end)
  end
end

defmodule ManifoldEngine.Benchmark.ClusterHelper do
  alias ManifoldEngine.Application

  def start_cluster(ports, caps \\ nil) do
    Enum.with_index(ports) |> Enum.each(fn {port, idx} ->
      cap = if caps, do: Enum.at(caps, idx), else: 10.0
      stop_node(port)
      Application.start_node(port, cap, cap)
      wait_until_listening(port)
    end)

    Enum.each(ports, fn port ->
      target = if port == List.last(ports), do: List.first(ports), else: port + 1
      try do
        s = ManifoldEngine.Node.get_state(port)
        payload = %{id: port, host: "127.0.0.1", port: port, capacity: s.capacity, memory: s.memory, current_load: 0.0, trust_index: 1.0}
        packet = %{type: "join", payload: payload}
        connect_and_send(~c"127.0.0.1", target, packet)
      rescue _ -> :ok end
    end)
    Process.sleep(1000)
  end

  def stop_all(ports) do
    Enum.each(ports, &stop_node/1)
  end

  defp stop_node(port) do
    Enum.each([ManifoldEngine.Node, ManifoldEngine.Networking, ManifoldEngine.Gossip, ManifoldEngine.Topology], fn mod ->
      name = mod.name(port)
      try do
        case GenServer.whereis(name) do
          nil -> :ok
          pid ->
            Supervisor.terminate_child(ManifoldEngine.Supervisor, {mod, port})
            Process.exit(pid, :kill)
        end
      rescue _ -> :ok end
    end)
  end

  defp wait_until_listening(port, retries \\ 20) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: 4, active: false], 100) do
      {:ok, socket} -> :gen_tcp.close(socket); :ok
      _ when retries > 0 -> Process.sleep(200); wait_until_listening(port, retries - 1)
      _ -> :error
    end
  end

  def connect_and_send(host, port, packet, retries \\ 10) do
    case :gen_tcp.connect(host, port, [:binary, packet: 4, active: false], 1000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, :erlang.term_to_binary(packet))
        :gen_tcp.close(socket)
      {:error, _} when retries > 0 ->
        Process.sleep(500)
        connect_and_send(host, port, packet, retries - 1)
      {:error, _} -> :ok
    end
  end
end

defmodule ManifoldEngine.Benchmark do
  alias ManifoldEngine.{Native, Task, LedgerSupervisor}
  alias ManifoldEngine.Benchmark.{ElixirVM, ClusterHelper}

  def run_suite_a do
    IO.puts "\n--- [SUITE A: GEOMETRIC ROUTING ANALYSIS] ---"
    task_weights = Enum.map(1..1000, fn _ -> if :rand.uniform() > 0.9, do: 10.0, else: 1.0 end)

    hete_nodes = [
      %{id: 1, load: 0.0, capacity: 20.0, memory: 20.0},
      %{id: 2, load: 0.0, capacity: 10.0, memory: 10.0},
      %{id: 3, load: 0.0, capacity: 5.0, memory: 5.0},
      %{id: 4, load: 0.0, capacity: 2.0, memory: 2.0},
      %{id: 5, load: 0.0, capacity: 1.0, memory: 1.0}
    ]

    homo_nodes = Enum.map(1..5, fn i -> %{id: i, load: 0.0, capacity: 10.0, memory: 10.0} end)

    results_hete = [{"Manifold (L3)", simulate_routing(task_weights, hete_nodes, :manifold)}, {"P2C (Sampling)", simulate_routing(task_weights, hete_nodes, :p2c)}, {"Round Robin", simulate_routing(task_weights, hete_nodes, :rr)}]
    results_homo = [{"Manifold (L3)", simulate_routing(task_weights, homo_nodes, :manifold)}, {"P2C (Sampling)", simulate_routing(task_weights, homo_nodes, :p2c)}, {"Round Robin", simulate_routing(task_weights, homo_nodes, :rr)}]

    IO.puts "\n[Heterogeneous Cluster]"
    Enum.each(results_hete, fn {name, var} -> IO.puts "#{String.pad_trailing(name, 15)} | Variance: #{:erlang.float_to_binary(var, decimals: 4)}" end)
    IO.puts "\n[Homogeneous Cluster]"
    Enum.each(results_homo, fn {name, var} -> IO.puts "#{String.pad_trailing(name, 15)} | Variance: #{:erlang.float_to_binary(var, decimals: 4)}" end)

    save_csv("benchmark_suite_a_hete.csv", ["algorithm", "variance"], results_hete)
    save_csv("benchmark_suite_a_homo.csv", ["algorithm", "variance"], results_homo)
  end

  defp simulate_routing(weights, nodes, algo) do
    final_nodes = case algo do
      :rr ->
        # NON-SIMPLIFIED Weighted Round Robin (WRR)
        total_cap = Enum.reduce(nodes, 0.0, fn n, acc -> acc + n.capacity end)
        Enum.reduce(weights, nodes, fn w, ns ->
          r = :rand.uniform() * total_cap
          selected_id = find_wrr_target(ns, r)
          Enum.map(ns, fn n -> if n.id == selected_id, do: %{n | load: n.load + w}, else: n end)
        end)
      _ ->
        Enum.reduce(weights, nodes, fn w, ns ->
          selected = case algo do
            :manifold ->
              Enum.min_by(ns, fn n ->
                load_ratio = n.load / n.capacity
                distortion = :math.exp(2 * load_ratio)
                # Ratio-Based Metric (R/C)^3 with R=1.0
                (:math.pow(1.0 / n.capacity, 3)) * distortion
              end)
            :p2c ->
              # NON-SIMPLIFIED Capacity-Aware P2C
              [n1, n2] = Enum.take_random(ns, 2)
              if (n1.load / n1.capacity) <= (n2.load / n2.capacity), do: n1, else: n2
          end
          Enum.map(ns, fn n -> if n.id == selected.id, do: %{n | load: n.load + w}, else: n end)
        end)
    end
    ratios = Enum.map(final_nodes, fn n -> n.load / n.capacity end)
    avg = Enum.sum(ratios) / length(ratios)
    Enum.sum(Enum.map(ratios, fn r -> :math.pow(r - avg, 2) end)) / length(ratios)
  end

  defp find_wrr_target([n | rest], r) do
    if r <= n.capacity, do: n.id, else: find_wrr_target(rest, r - n.capacity)
  end
  defp find_wrr_target([], _), do: 1

  def run_suite_b do
    IO.puts "\n--- [SUITE B: MITOSIS EFFICIENCY U-CURVE] ---"
    ports = [20001, 20002, 20003, 20004, 20005]
    entry_port = hd(ports)
    ClusterHelper.start_cluster(ports)

    parent = self()
    callback_port = 20006

    {:ok, l} = :gen_tcp.listen(callback_port, [:binary, packet: 4, active: false, reuseaddr: true])
    spawn(fn -> accept_loop_results(l, parent) end)

    program = [{:loop, 100_000, 3}, {:push, 1.0}, {:push, 1.0}, :add]
    shard_counts = [1, 2, 4, 8, 16]

    results = Enum.map(shard_counts, fn shards ->
      job_id = "mitosis_#{shards}_#{:erlang.unique_integer([:positive])}"
      {t, result} = :timer.tc(fn ->
        LedgerSupervisor.start_ledger([job_id: job_id, original_task_id: "bench_task",
                                       total_shards: shards, shard_ids: Enum.map(0..shards-1, &"s_#{&1}"),
                                       return_addr: {"127.0.0.1", callback_port},
                                       local_port: entry_port])
        Process.sleep(500)

        step = 100.0 / shards
        Enum.each(0..(shards - 1), fn i ->
          task = %Task{id: "s_#{i}", program: program, start: i*step, end: (i+1)*step, parent_job_id: job_id, is_subtask: true, return_addr: {"127.0.0.1", entry_port}}
          send_via_tcp(Enum.at(ports, rem(i, 5)), task)
        end)

        receive do
          {:job_done, ^job_id} -> :ok
        after 30000 -> :timeout
        end
      end)
      ms = t / 1000
      IO.puts "Shards: #{String.pad_leading(to_string(shards), 2)} | Total Time: #{ms} ms | Result: #{result}"
      {shards, ms}
    end)

    :gen_tcp.close(l)
    ClusterHelper.stop_all(ports)
    save_csv("benchmark_suite_b.csv", ["shards", "ms"], results)
  end

  defp accept_loop_results(l, parent) do
    case :gen_tcp.accept(l) do
      {:ok, s} ->
        spawn(fn ->
          case :gen_tcp.recv(s, 0) do
            {:ok, data} ->
              case :erlang.binary_to_term(data) do
                %{type: "result", payload: %{parent_job_id: jid}} -> send(parent, {:job_done, jid})
                _ -> :ok
              end
            _ -> :ok
          end
          :gen_tcp.close(s)
        end)
        accept_loop_results(l, parent)
      _ -> :ok
    end
  end

  def run_suite_c do
    IO.puts "\n--- [SUITE C: CONSENSUS QUORUM SCALING] ---"
    sizes = [1, 3, 5]
    Logger.configure(level: :error)
    Application.ensure_all_started(:ra); :ra.start()

    results = Enum.map(sizes, fn n ->
      cluster_name = :"raft_#{n}_#{:erlang.unique_integer([:positive])}"
      members = Enum.map(1..n, fn i -> {:"n_#{n}_#{i}", Node.self()} end)
      {:ok, _, _} = :ra.start_cluster(:default, cluster_name, {:module, ManifoldEngine.DSM.Machine, %{}}, members)
      Process.sleep(1000)
      leader = hd(members)
      {t, _} = :timer.tc(fn -> Enum.each(1..20, fn i -> :ra.process_command(leader, {:put, "k#{i}", i}) end) end)
      avg_lat = (t / 1000) / 20
      IO.puts "Nodes: #{n} | Avg Commit Latency: #{:erlang.float_to_binary(avg_lat, decimals: 4)} ms"
      {n, avg_lat}
    end)
    Logger.configure(level: :debug)
    save_csv("benchmark_suite_c.csv", ["nodes", "latency_ms"], results)
  end

  def run_suite_d do
    IO.puts "\n--- [SUITE D: DATA PLANE JUSTIFICATION (CROSSOVER)] ---"
    workloads = [
      {"Micro (10 ops)", [{:loop, 10, 1}, {:push, 1.0}]},
      {"Med (10k ops)", [{:loop, 10_000, 1}, {:push, 1.0}]},
      {"Heavy (1M ops)", [{:loop, 1_000_000, 1}, {:push, 1.0}]}
    ]
    Benchee.run(%{"Elixir VM" => fn prog -> ElixirVM.execute_task(prog, 0.0, 1.0) end, "Rust NIF"  => fn prog -> Native.execute_task(prog, 0.0, 1.0) end}, inputs: workloads, time: 2, memory_time: 1, formatters: [Benchee.Formatters.Console, {Benchee.Formatters.CSV, file: "benchmark_suite_d.csv"}])
  end

  def run_suite_e do
    IO.puts "\n--- [SUITE E: TAIL LATENCY & CASCADING FAILURE] ---"
    IO.puts "\n[1000 Tasks Sustained Load]"
    stats_1000 = ManifoldEngine.Benchmark.TailLatency.run(1000, 500, 30000)

    IO.puts "\n[5000 Tasks Sustained Load (Cascading Failure Test)]"
    stats_5000 = ManifoldEngine.Benchmark.TailLatency.run(5000, 500, 40000)

    save_tail_csv("benchmark_suite_e_1000.csv", stats_1000)
    save_tail_csv("benchmark_suite_e_5000.csv", stats_5000)
  end

  defp save_tail_csv(filename, stats) do
    headers = "algo,p10,p25,p50,p75,p90,p95,p99,p99_9,max\n"
    rows = Enum.map([manifold: stats.manifold, p2c: stats.p2c], fn {algo, s} ->
      "#{algo},#{s.p10},#{s.p25},#{s.p50},#{s.p75},#{s.p90},#{s.p95},#{s.p99},#{s.p99_9},#{s.max}"
    end) |> Enum.join("\n")
    File.write!(filename, headers <> rows)
  end

  defp send_via_tcp(port, packet) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: 4, active: false], 1000) do
      {:ok, s} ->
        res = :gen_tcp.send(s, :erlang.term_to_binary(%{type: "task", payload: packet}))
        :gen_tcp.close(s)
        res
      {:error, err} -> {:error, err}
    end
  end

  defp save_csv(filename, headers, rows) do
    content = Enum.join(headers, ",") <> "\n" <> (rows |> Enum.map(fn {name, val} -> "#{name},#{val}"; t when is_tuple(t) -> t |> Tuple.to_list() |> Enum.join(",") end) |> Enum.join("\n"))
    File.write!(filename, content)
  end
end

ManifoldEngine.Benchmark.run_suite_a()
ManifoldEngine.Benchmark.run_suite_b()
ManifoldEngine.Benchmark.run_suite_c()
ManifoldEngine.Benchmark.run_suite_d()
ManifoldEngine.Benchmark.run_suite_e()
