defmodule ManifoldEngine.Gossip do
  @moduledoc """
  The epidemic directory propagation engine.
  
  Ensures that resource state and peer knowledge are disseminated 
  through the cluster using recursive neighbor synchronization.
  """
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
    
    # Epidemic strategy: share the entire known universe, not just local state.
    # This ensures O(log N) convergence even if nodes join/leave.
    self_state = Map.take(node_state, [:id, :host, :port, :capacity, :memory, :current_load, :trust_index])
    peers_to_send = %{node_state.id => self_state} |> Map.merge(node_state.peers)
    packet = %{type: "gossip", payload: {:batch, peers_to_send}}
    
    Enum.each(node_state.neighbors, fn neighbor_id ->
      send_packet(port, node_state.peers[neighbor_id], packet)
    end)

    schedule_gossip(state.interval)
    {:noreply, state}
  end

  defp send_packet(_, nil, _), do: :ok
  defp send_packet(local_port, peer, pkt) do
    Task.start(fn ->
      start_time = System.monotonic_time(:millisecond)
      try do
        {:ok, socket} = :gen_tcp.connect(String.to_charlist(peer.host), peer.port, [:binary, packet: 4, active: false], 1000)
        :gen_tcp.send(socket, :erlang.term_to_binary(pkt))
        :gen_tcp.close(socket)
        
        # Latency profiling: record RTT to update the geometric metric
        rtt = System.monotonic_time(:millisecond) - start_time
        Node.update_peer_latency(local_port, peer.id, rtt)
      rescue _ -> :ok end
    end)
  end

  defp schedule_gossip(interval), do: Process.send_after(self(), :gossip, interval)
end
