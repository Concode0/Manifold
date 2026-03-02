defmodule ManifoldEngine.Router do
  @moduledoc "Geometric routing for task offloading."
  alias ManifoldEngine.{Native, Node}

  @doc "Finds the best candidates based on manifold distance metric."
  def best_candidates(task_req, local_port, limit \\ 2) do
    node = Node.get_state(local_port)
    
    node.peers
    |> Map.values()
    |> Enum.filter(&(&1.id in node.neighbors))
    |> Enum.map(fn peer ->
      # Add small random noise to load to prevent "herd effect" when gossip is stale
      virtual_load = peer.current_load + (:rand.uniform() * 0.1)
      dist = Native.geometric_distance([peer.capacity, peer.memory], task_req, virtual_load, peer.capacity, peer.trust_index, 1.0)
      {peer, dist}
    end)
    |> Enum.sort_by(fn {_, dist} -> dist end)
    |> Enum.take(limit)
  end

  @doc "Sends a task packet to a remote node."
  def forward(task, peer) do
    # IO.puts "[ROUTER] Offloading task #{task.id} -> #{peer.port}"
    packet = %{type: "task", payload: task}
    Task.start(fn ->
      try do
        {:ok, s} = :gen_tcp.connect(String.to_charlist(peer.host), peer.port, [:binary, active: false], 2000)
        :gen_tcp.send(s, Jason.encode!(packet))
        :gen_tcp.close(s)
      rescue _ -> :ok end
    end)
  end
end
