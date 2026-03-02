# Run with: mix run simulator.exs
alias ManifoldEngine.{Node, Task, Client, Application}

IO.puts "--- [RESEARCH SIMULATION STARTING] ---"

# 1. Start global application
# mix run already starts the application, but we can call it manually if needed.
# Since we are using virtual nodes, we use Application.start_node/1

ports = [9001, 9002, 9003]
Enum.each(ports, fn port ->
  IO.puts "[SIM] Initializing Virtual Node on Port #{port}..."
  Application.start_node(port)
  Process.sleep(500) # Give each node time to bind its port
end)

IO.puts "[SIM] Nodes online. Waiting for Gossip/Topology to settle..."
Process.sleep(3000)

# 2. Bootstrap the Cluster (Manual Join for simulation)
Enum.each(ports, fn port ->
  target = if port == 9003, do: 9001, else: port + 1
  payload = %{id: port, host: "127.0.0.1", port: port, capacity: 10.0, memory: 10.0, current_load: 0.0, trust_index: 1.0}
  packet = %{type: "join", payload: payload}
  
  case :gen_tcp.connect(~c"127.0.0.1", target, [:binary, active: false], 1000) do
    {:ok, s} ->
      :gen_tcp.send(s, Jason.encode!(packet))
      :gen_tcp.close(s)
    {:error, reason} ->
      IO.puts "[SIM] Error connecting to #{target}: #{inspect(reason)}"
  end
end)

IO.puts "[SIM] Cluster interconnected. Submitting Task..."

# 3. Create a Heavy Task to trigger Mitosis
program = [
  {:loop, 100, 3},
  {:push, 1.0},
  {:push, 2.0},
  :add
]

task = %Task{
  id: "research_job_001",
  program: program,
  req: [0.9, 0.1],      # Demands high compute capacity
  start: 0,
  end: 10,              # Total Ops = 10 (range) * 100 (loop) = 1000
  return_addr: {"127.0.0.1", 9999},
  is_subtask: false
}

# 4. Visualizer: Show Cluster Dashboard
Application.start_visualizer(ports)

# 5. Client: Listen for the aggregated result and submit
Client.listen(9999)
Process.sleep(1000) # Give listener time to bind
Client.submit(task, "127.0.0.1", 9001)

# Keep simulation alive to observe dashboard
Process.sleep(30000)
