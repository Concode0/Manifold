defmodule ManifoldEngine.Visualizer do
  @moduledoc "TUI Dashboard for the Manifold Cluster."
  use GenServer
  alias ManifoldEngine.Node

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    # High-frequency refresh for real-time observation
    Process.send_after(self(), :render, 100)
    {:ok, %{ports: opts[:ports]}}
  end

  @impl true
  def handle_info(:render, state) do
    IO.write([IO.ANSI.home(), IO.ANSI.clear()])
    IO.puts IO.ANSI.bright() <> "=== MANIFOLD GEOMETRIC OS DASHBOARD ===" <> IO.ANSI.reset()
    IO.puts "Time: #{DateTime.now!("Etc/UTC")} | Nodes: #{length(state.ports)}"
    IO.puts String.duplicate("-", 65)
    IO.puts "| Port  | Load Status | Trust | Cap   | Press | Neighbors          |"
    IO.puts String.duplicate("-", 65)

    Enum.each(state.ports, fn port ->
      name = Node.name(port)
      if Process.whereis(name) do
        try do
          node = Node.get_state(port)
          load_pct = (node.current_load / node.capacity * 100) |> Float.round(1)
          
          # Visual Load Bar
          bar_len = round(load_pct / 10)
          bar = String.duplicate("█", min(10, bar_len)) |> String.pad_trailing(10)
          
          color = cond do
            load_pct > 80 -> IO.ANSI.red()
            load_pct > 30 -> IO.ANSI.yellow()
            load_pct > 0  -> IO.ANSI.cyan()
            true -> IO.ANSI.green()
          end

          formatted_neighbors = Enum.join(node.neighbors, ", ")
          
          :io.format("| ~w | ~s~s~s ~5.1f% | ~4.2f  | ~5.1f | ~3w   | ~-18s |~n", [
            port, color, bar, IO.ANSI.reset(), load_pct, 
            node.trust_index, node.capacity, node.ledger_pressure, formatted_neighbors
          ])
        rescue
          _ -> :ok end
      else
        :io.format("| ~w | OFFLINE     |       |       |       |                    |~n", [port])
      end
    end)
    IO.puts String.duplicate("-", 65)

    Process.send_after(self(), :render, 100)
    {:noreply, state}
  end
end
