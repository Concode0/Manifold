defmodule ManifoldEngine.Application do
  @moduledoc "Supervision tree for the Geometric Distributed OS."
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

  def start_node(port) do
    children = [
      {ManifoldEngine.Node, [port: port, capacity: 10.0, memory: 10.0]},
      {ManifoldEngine.Networking, [port: port]},
      {ManifoldEngine.Gossip, [interval: 2000, port: port]},
      {ManifoldEngine.Topology, [interval: 5000, port: port]}
    ]
    Enum.each(children, fn {module, opts} ->
      Supervisor.start_child(ManifoldEngine.Supervisor, {module, opts})
    end)
  end

  def start_visualizer(ports) do
    Supervisor.start_child(ManifoldEngine.Supervisor, {ManifoldEngine.Visualizer, [ports: ports]})
  end
end
