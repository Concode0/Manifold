defmodule ManifoldEngine.Topology do
  @moduledoc """
  Maintains the Small World network topology of the cluster.
  
  Periodically evaluates the geometric distance to all known peers 
  and updates active links to prioritize local geometric neighbors 
  while maintaining stochastic long-range shortcuts.
  """
  use GenServer
  alias ManifoldEngine.{Node, Native}

  def name(port), do: :"Topology_#{port}"

  def start_link(opts) do
    port = opts[:port]
    GenServer.start_link(__MODULE__, opts, name: name(port))
  end

  @impl true
  def init(opts) do
    interval = opts[:interval] || 5000
    schedule_maintenance(interval)
    {:ok, %{interval: interval, port: opts[:port]}}
  end

  @impl true
  def handle_info(:maintenance, %{port: port} = state) do
    node_state = Node.get_state(port)
    peers = Map.values(node_state.peers)
    n_count = length(peers)
    
    if n_count > 0 do
      # Small world neighbor count: O(log N) scaling
      neighbor_count = max(2, round(:math.log(n_count + 1)))

      # Evaluate geometric proximity using Minkowski L3 metric
      sorted_peers = Enum.map(peers, fn peer ->
        latency = Map.get(peer, :latency, 1.0)
        current_load = Map.get(peer, :current_load, 0.0)
        dist = Native.geometric_distance(
          [node_state.capacity, node_state.memory],
          [peer.capacity, peer.memory],
          current_load, peer.capacity, peer.trust_index || 1.0, latency
        )
        {peer.id, dist}
      end) |> Enum.sort_by(fn {_, dist} -> dist end)

      # 1. K-local neighbors: the geographically closest nodes
      k_local = sorted_peers |> Enum.take(neighbor_count) |> Enum.map(fn {id, _} -> id end)
      
      # 2. Long-range shortcuts: stochastic links to ensure O(log n) diameter
      m_long = sorted_peers |> Enum.drop(neighbor_count) |> Enum.take_random(neighbor_count) |> Enum.map(fn {id, _} -> id end)

      Node.update_neighbors(port, Enum.uniq(k_local ++ m_long))
    end

    schedule_maintenance(state.interval)
    {:noreply, state}
  end

  defp schedule_maintenance(interval), do: Process.send_after(self(), :maintenance, interval)
end
