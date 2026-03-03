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
    final_nodes = Enum.reduce(weights, nodes, fn w, ns ->
      selected = case algo do
        :manifold ->
          Enum.min_by(ns, fn n ->
            load_ratio = n.load / n.capacity
            distortion = :math.exp(2 * load_ratio)
            (1.0 / n.capacity) * distortion
          end)
        :p2c ->
          [n1, n2] = Enum.take_random(ns, 2)
          if (n1.load/n1.capacity) <= (n2.load/n2.capacity), do: n1, else: n2
        :rr ->
          Enum.at(ns, :erlang.unique_integer([:positive]) |> rem(length(ns)))
      end
      Enum.map(ns, fn n -> if n.id == selected.id, do: %{n | load: n.load + w}, else: n end)
    end)
    ratios = Enum.map(final_nodes, fn n -> n.load / n.capacity end)
    avg = Enum.sum(ratios) / length(ratios)
    Enum.sum(Enum.map(ratios, fn r -> :math.pow(r - avg, 2) end)) / length(ratios)
  end

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
