defmodule ManifoldEngine.Visualizer do
  @moduledoc "TUI Dashboard for the Manifold Cluster."
  use GenServer
  alias ManifoldEngine.Node

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.send_after(self(), :render, 1000)
    {:ok, %{ports: opts[:ports]}}
  end

  @impl true
  def handle_info(:render, state) do
    IO.write([IO.ANSI.home(), IO.ANSI.clear()])
    IO.puts IO.ANSI.bright() <> "=== MANIFOLD GEOMETRIC OS DASHBOARD ===" <> IO.ANSI.reset()
    IO.puts "Time: #{DateTime.now!("Etc/UTC")} | Nodes: #{length(state.ports)}"
    IO.puts String.duplicate("-", 60)
    IO.puts "| Port | Load  | Trust | Capacity | Neighbors          |"
    IO.puts String.duplicate("-", 60)

    Enum.each(state.ports, fn port ->
      name = Node.name(port)
      if Process.whereis(name) do
        try do
          node = Node.get_state(port)
          load_pct = (node.current_load / node.capacity * 100) |> Float.round(1)
          
          color = cond do
            load_pct > 80 -> IO.ANSI.red()
            load_pct > 50 -> IO.ANSI.yellow()
            true -> IO.ANSI.green()
          end

          formatted_neighbors = Enum.join(node.neighbors, ", ")
          
          :io.format("| ~w | ~s~5.1f%~s | ~4.2f  | ~7.1f  | ~-18s |~n", [
            port, color, load_pct, IO.ANSI.reset(), node.trust_index, node.capacity, formatted_neighbors
          ])
        rescue
          _ -> :ok
        end
      else
        :io.format("| ~w | OFFLINE |       |          |                    |~n", [port])
      end
    end)
    IO.puts String.duplicate("-", 60)

    Process.send_after(self(), :render, 1000)
    {:noreply, state}
  end
end
