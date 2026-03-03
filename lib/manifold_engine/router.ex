defmodule ManifoldEngine.Router do
  @moduledoc """
  The scheduling engine of the Geometric Distributed OS.
  
  Uses the Minkowski L3 metric to calculate the 'Geometric Distance' 
  between a task's requirements and a node's physical features.
  """
  alias ManifoldEngine.{Native, Node}

  @doc """
  Finds the best candidate nodes for a task based on geometric proximity.
  Implements Power of Two Choices (P2C) sampling if the candidate pool is large.
  """
  def best_candidates(task_req, local_port, limit \\ 2) do
    node = Node.get_state(local_port)

    # Filter for active Small World links
    candidates = node.peers
    |> Map.values()
    |> Enum.filter(&(&1.id in node.neighbors))

    if length(candidates) <= limit do
      candidates
      |> Enum.map(fn peer -> {peer, calculate_dist(peer, node, task_req)} end)
      |> Enum.sort_by(fn {_, dist} -> dist end)
    else
      # P2C sampling: reduces O(n) search to O(ln ln n) stability
      candidates
      |> Enum.take_random(limit * 2)
      |> Enum.map(fn peer -> {peer, calculate_dist(peer, node, task_req)} end)
      |> Enum.sort_by(fn {_, dist} -> dist end)
      |> Enum.take(limit)
    end
  end

  defp calculate_dist(peer, _node, task_req) do
    # Composite load: Total stress = Execution Load + Aggregation (Ledger) Pressure
    # This ensures that coordination overhead warps the geometry just like CPU usage.
    total_stress = peer.current_load + (Map.get(peer, :ledger_pressure, 0) * 0.5)

    jitter = :rand.uniform() * 0.01
    latency = Map.get(peer, :latency, 1.0)
    
    # Delegate Minkowski L3 calculation to the accelerated data plane (Rust)
    Native.geometric_distance(
      [peer.capacity, peer.memory], 
      task_req, 
      total_stress + jitter, 
      peer.capacity, 
      peer.trust_index || 1.0, 
      latency
    )
  end

  @doc "Forwards a task packet to a peer using length-prefixed ETF."
  def forward(task, peer) do
    packet = %{type: "task", payload: task}
    Task.start(fn ->
      try do
        {:ok, s} = :gen_tcp.connect(String.to_charlist(peer.host), peer.port, [:binary, packet: 4, active: false], 2000)
        :gen_tcp.send(s, :erlang.term_to_binary(packet))
        :gen_tcp.close(s)
      rescue _ -> :ok end
    end)
  end
end
