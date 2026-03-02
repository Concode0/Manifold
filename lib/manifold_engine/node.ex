defmodule ManifoldEngine.Node do
  @moduledoc "Centralized state management for a Manifold Node."
  use GenServer

  defstruct [
    :id, :host, :port, :capacity, :memory, :current_load, :trust_index,
    peers: %{},        # %{id => %{features, load, ts}}
    neighbors: []      # Active Small World links
  ]

  def name(port), do: :"Node_#{port}"

  def start_link(opts) do
    port = opts[:port]
    GenServer.start_link(__MODULE__, opts, name: name(port))
  end

  def get_state(port), do: GenServer.call(name(port), :get_state)
  def update_load(port, delta), do: GenServer.cast(name(port), {:update_load, delta})
  def record_peer_state(port, peer_info), do: GenServer.cast(name(port), {:record_peer, peer_info})
  def update_neighbors(port, neighbors), do: GenServer.cast(name(port), {:update_neighbors, neighbors})

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{
      id: opts[:port], host: opts[:host] || "127.0.0.1", port: opts[:port],
      capacity: opts[:capacity] || 10.0, memory: opts[:memory] || 10.0,
      current_load: 0.0, trust_index: 1.0, peers: %{}
    }}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:update_load, delta}, state) do
    {:noreply, %{state | current_load: state.current_load + delta}}
  end

  @impl true
  def handle_cast({:record_peer, peer}, state) do
    # Record peer state and timestamp for liveness tracking.
    new_peers = Map.put(state.peers, peer.id, Map.put(peer, :ts, System.monotonic_time(:millisecond)))
    {:noreply, %{state | peers: new_peers}}
  end

  @impl true
  def handle_cast({:update_neighbors, neighbors}, state) do
    {:noreply, %{state | neighbors: neighbors}}
  end
end
