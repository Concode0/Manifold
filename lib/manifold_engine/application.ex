defmodule ManifoldEngine.Application do
  
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, [keys: :unique, name: ManifoldEngine.LedgerRegistry]},
      ManifoldEngine.LedgerSupervisor
    ]

    opts = [strategy: :one_for_one, name: ManifoldEngine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def start_node(port, capacity \\ nil, memory \\ nil) do
    children_specs = [
      %{id: {ManifoldEngine.Node, port}, start: {ManifoldEngine.Node, :start_link, [[port: port, capacity: capacity, memory: memory]]}},
      %{id: {ManifoldEngine.Networking, port}, start: {ManifoldEngine.Networking, :start_link, [[port: port]]}},
      %{id: {ManifoldEngine.Gossip, port}, start: {ManifoldEngine.Gossip, :start_link, [[interval: 2000, port: port]]}},
      %{id: {ManifoldEngine.Topology, port}, start: {ManifoldEngine.Topology, :start_link, [[interval: 5000, port: port]]}}
    ]
    Enum.each(children_specs, fn spec ->
      Supervisor.start_child(ManifoldEngine.Supervisor, spec)
    end)
  end

  def start_visualizer(ports) do
    Supervisor.start_child(ManifoldEngine.Supervisor, {ManifoldEngine.Visualizer, [ports: ports]})
  end
end
