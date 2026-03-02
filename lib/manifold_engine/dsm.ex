defmodule ManifoldEngine.DSM do
  @moduledoc """
  Distributed Shared Memory built on the Raft consensus protocol.
  """

  @cluster_name :manifold_dsm

  @doc """
  Starts the local Raft server for this node.
  `node_id` is a unique identifier (e.g., node port or atom).
  `members` is a list of `{id, node}` tuples for the initial cluster.
  """
  def start_server(_node_id, members) do
    machine = {:module, ManifoldEngine.DSM.Machine, %{}}
    :ra.start_cluster(:default, @cluster_name, machine, members)
  end

  @doc """
  Stores a value globally.
  """
  def put(server_id, key, value) do
    case :ra.process_command(server_id, {:put, key, value}) do
      {:ok, _result, _leader} -> :ok
      error -> error
    end
  end

  @doc """
  Loads a value globally.
  """
  def get(server_id, key) do
    # Note: process_command goes through Raft consensus. 
    # For local reads (potentially stale), :ra.local_query could be used.
    case :ra.process_command(server_id, {:get, key}) do
      {:ok, result, _leader} -> {:ok, result}
      error -> error
    end
  end

  @doc """
  Atomic Compare-and-Swap.
  """
  def cas(server_id, key, old_val, new_val) do
    case :ra.process_command(server_id, {:cas, key, old_val, new_val}) do
      {:ok, {:ok, _val}, _leader} -> :ok
      {:ok, {:error, reason}, _leader} -> {:error, reason}
      error -> error
    end
  end
end
