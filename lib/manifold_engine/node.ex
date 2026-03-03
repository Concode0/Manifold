defmodule ManifoldEngine.Node do
  @moduledoc """
  The Control Plane process representing a single Geometric Node.
  
  Maintains the local state of the node, including resource capacities, 
  current execution load, and the directory of known cluster peers.
  """
  use GenServer

  defstruct [
    :id, :host, :port, :capacity, :memory, :current_load, :trust_index,
    peers: %{},        # %{id => %{features, load, ts, latency}}
    neighbors: [],      # Active Small World links
    ledger_pressure: 0  # BACK-PRESSURE: count of active aggregation ledgers
  ]

  def name(port), do: :"Node_#{port}"

  def start_link(opts) do
    port = opts[:port]
    GenServer.start_link(__MODULE__, opts, name: name(port))
  end

  @doc "Retrieves the full internal state of the node."
  def get_state(port), do: GenServer.call(name(port), :get_state)

  @doc "Updates the local computational load (delta)."
  def update_load(port, delta), do: GenServer.cast(name(port), {:update_load, delta})

  @doc "Records or updates state for a single peer or a batch of peers (epidemic gossip)."
  def record_peer_state(port, peer_info), do: GenServer.cast(name(port), {:record_peer, peer_info})

  @doc "Updates the active Small World neighbor list."
  def update_neighbors(port, neighbors), do: GenServer.cast(name(port), {:update_neighbors, neighbors})

  @doc "Records the observed round-trip time (RTT) for a peer."
  def update_peer_latency(port, peer_id, rtt), do: GenServer.cast(name(port), {:update_peer_latency, peer_id, rtt})

  @doc "Halves the trust index of a peer after a failure or timeout."
  def penalize_peer(port, peer_id), do: GenServer.cast(name(port), {:penalize_peer, peer_id})

  @doc "Updates the count of active aggregation ledgers for back-pressure signaling."
  def update_ledger_pressure(port, delta), do: GenServer.cast(name(port), {:update_ledger_pressure, delta})

  @impl true
  def init(opts) do
    cores = opts[:capacity] || (:erlang.system_info(:logical_processors) * 1.0)
    mem_gb = opts[:memory] || (:erlang.memory(:total) / (1024 * 1024 * 1024))
    {:ok, %__MODULE__{
      id: opts[:port], host: opts[:host] || "127.0.0.1", port: opts[:port],
      capacity: cores, memory: mem_gb,
      current_load: 0.0, trust_index: 1.0, peers: %{},
      ledger_pressure: 0
    }}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:update_load, delta}, state) do
    {:noreply, %{state | current_load: state.current_load + delta}}
  end

  @impl true
  def handle_cast({:record_peer, {:batch, peers}}, state) do
    # Epidemic merge: recursively integrate foreign directories
    new_peers = Enum.reduce(peers, state.peers, fn {id, info}, acc ->
      if id == state.id do
        acc
      else
        existing_latency = get_in(acc, [id, :latency]) || 1.0
        existing_trust = get_in(acc, [id, :trust_index]) || 1.0
        new_trust = min(1.0, existing_trust + 0.05)
        info_map = if is_struct(info), do: Map.from_struct(info), else: info
        new_peer = Map.merge(info_map, %{ts: System.monotonic_time(:millisecond), latency: existing_latency, trust_index: new_trust})
        Map.put(acc, id, new_peer)
      end
    end)
    {:noreply, %{state | peers: new_peers}}
  end

  def handle_cast({:record_peer, peer}, state) do
    id = if is_struct(peer), do: peer.id, else: peer[:id]
    if id == nil or id == state.id do
      {:noreply, state}
    else
      existing_latency = get_in(state.peers, [id, :latency]) || 1.0
      existing_trust = get_in(state.peers, [id, :trust_index]) || 1.0
      new_trust = min(1.0, existing_trust + 0.05) 
      
      peer_map = if is_struct(peer), do: Map.from_struct(peer), else: peer
      new_peer = Map.merge(peer_map, %{ts: System.monotonic_time(:millisecond), latency: existing_latency, trust_index: new_trust})
      new_peers = Map.put(state.peers, id, new_peer)
      {:noreply, %{state | peers: new_peers}}
    end
  end

  @impl true
  def handle_cast({:update_neighbors, neighbors}, state) do
    {:noreply, %{state | neighbors: neighbors}}
  end

  @impl true
  def handle_cast({:update_peer_latency, peer_id, rtt}, state) do
    new_peers = case Map.get(state.peers, peer_id) do
      nil -> state.peers
      peer -> Map.put(state.peers, peer_id, Map.put(peer, :latency, rtt))
    end
    {:noreply, %{state | peers: new_peers}}
  end

  @impl true
  def handle_cast({:penalize_peer, peer_id}, state) do
    new_peers = case Map.get(state.peers, peer_id) do
      nil -> state.peers
      peer -> 
        new_trust = max(0.01, (peer.trust_index || 1.0) * 0.5)
        Map.put(state.peers, peer_id, Map.put(peer, :trust_index, new_trust))
    end
    {:noreply, %{state | peers: new_peers}}
  end

  @impl true
  def handle_cast({:update_ledger_pressure, delta}, state) do
    {:noreply, %{state | ledger_pressure: max(0, state.ledger_pressure + delta)}}
  end
end
