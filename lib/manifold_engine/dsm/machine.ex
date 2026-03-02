defmodule ManifoldEngine.DSM.Machine do
  @moduledoc "Raft State Machine: Atomic deterministic key-value store."
  @behaviour :ra_machine

  @impl :ra_machine
  def init(_), do: %{}

  @impl :ra_machine
  def apply(_meta, command, state) do
    # Raft Apply: Deterministic state updates replicated across quorum.
    case command do
      {:put, key, val} -> {Map.put(state, key, val), :ok, []}
      {:get, key} -> {state, Map.get(state, key), []}
      {:cas, key, old, new} ->
        current = Map.get(state, key)
        if current == old, do: {Map.put(state, key, new), {:ok, new}, []}, else: {state, {:error, {:cas_failed, current}}, []}
    end
  end
end
