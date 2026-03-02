defmodule ManifoldEngine.Topology do
  @moduledoc "Manages Small World topology using geometric distance links."
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
    
    if length(peers) > 0 do
      sorted_peers = Enum.map(peers, fn peer ->
        dist = Native.geometric_distance(
          [node_state.capacity, node_state.memory],
          [peer.capacity, peer.memory],
          peer.current_load, peer.capacity, peer.trust_index, 1.0
        )
        {peer.id, dist}
      end) |> Enum.sort_by(fn {_, dist} -> dist end)

      k_local = sorted_peers |> Enum.take(2) |> Enum.map(fn {id, _} -> id end)
      m_long = sorted_peers |> Enum.drop(2) |> Enum.take_random(2) |> Enum.map(fn {id, _} -> id end)

      Node.update_neighbors(port, Enum.uniq(k_local ++ m_long))
    end

    schedule_maintenance(state.interval)
    {:noreply, state}
  end

  defp schedule_maintenance(interval), do: Process.send_after(self(), :maintenance, interval)
end
