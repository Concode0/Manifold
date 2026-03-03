defmodule ManifoldEngine.DSM do
  @moduledoc """
  The Distributed Shared Memory (DSM) interface.
  
  Provides an atomic, consistent key-value store across the cluster 
  using the Raft consensus protocol.
  """

  @cluster_name :manifold_dsm

  @doc "Starts a Raft cluster for the DSM with the given member nodes."
  def start_server(_node_id, members) do
    machine = {:module, ManifoldEngine.DSM.Machine, %{}}
    :ra.start_cluster(:default, @cluster_name, machine, members)
  end

  @doc "Atomically puts a value into the global DSM."
  def put(server_id, key, value) do
    case :ra.process_command(server_id, {:put, key, value}) do
      {:ok, :ok, _leader} -> :ok
      {:ok, reply, _leader} -> reply
      error -> error
    end
  end

  @doc "Retrieves a value from the global DSM."
  def get(server_id, key) do
    case :ra.process_command(server_id, {:get, key}) do
      {:ok, result, _leader} -> {:ok, result}
      error -> error
    end
  end

  @doc "Performs an atomic Compare-And-Swap (CAS) operation."
  def cas(server_id, key, old_val, new_val) do
    # Raft ensures that CAS is linearizable across the cluster.
    case :ra.process_command(server_id, {:cas, key, old_val, new_val}) do
      {:ok, {:ok, val}, _leader} -> {:ok, val}
      {:ok, {:error, reason}, _leader} -> {:error, reason}
      {:ok, reply, _leader} -> reply
      error -> error
    end
  end
end
