defmodule ManifoldEngine.Gossip do
  @moduledoc "Periodic state broadcast for peer discovery and load balancing."
  use GenServer
  alias ManifoldEngine.Node

  def name(port), do: :"Gossip_#{port}"

  def start_link(opts) do
    port = opts[:port]
    GenServer.start_link(__MODULE__, opts, name: name(port))
  end

  @impl true
  def init(opts) do
    schedule_gossip(opts[:interval] || 2000)
    {:ok, %{interval: opts[:interval] || 2000, port: opts[:port]}}
  end

  @impl true
  def handle_info(:gossip, %{port: port} = state) do
    node_state = Node.get_state(port)
    packet = %{type: :gossip, payload: Map.take(node_state, [:id, :host, :port, :capacity, :memory, :current_load, :trust_index])}
    
    Enum.each(node_state.neighbors, fn neighbor_id ->
      send_packet(node_state.peers[neighbor_id], packet)
    end)

    schedule_gossip(state.interval)
    {:noreply, state}
  end

  defp send_packet(nil, _), do: :ok
  defp send_packet(peer, pkt) do
    Task.start(fn ->
      try do
        {:ok, socket} = :gen_tcp.connect(String.to_charlist(peer.host), peer.port, [:binary, active: false], 1000)
        :gen_tcp.send(socket, Jason.encode!(pkt))
        :gen_tcp.close(socket)
      rescue _ -> :ok end
    end)
  end

  defp schedule_gossip(interval), do: Process.send_after(self(), :gossip, interval)
end
