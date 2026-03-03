defmodule ManifoldEngine.Task do
  @moduledoc """
  The primary data structure for computational workloads in the Manifold Cluster.
  
  Contains the VM instruction set, Minkowski requirements, and metadata 
  required for mitosis and result aggregation.
  """
  
  @derive Jason.Encoder
  defstruct [
    :id, 
    :program,       # List of VM instructions
    :req,           # Minkowski Requirements: [Capacity, Memory]
    :effort,        # Predicted computational cost from Static Analysis
    :start,         # Execution range start (used for sharding)
    :end,           # Execution range end
    :return_addr,   # {host, port} for result delivery
    :parent_job_id, # Link to parent Ledger if this is a shard
    :is_subtask,    # Flag to prevent recursive mitosis
    :reducer,       # Reduction logic: :sum, :min, :max, etc.
    status: :pending
  ]

  @doc """
  Normalizes program instructions, converting JSON-style strings to internal tuples.
  Ensures numerical stability by forcing floats where necessary.
  """
  def normalize_program(nil), do: []
  def normalize_program(program) when is_list(program) do
    Enum.map(program, fn
      ["push", val] -> {:push, val / 1.0}
      ["load", addr] -> {:load, addr}
      ["store", addr] -> {:store, addr}
      ["loop", iters, len] -> {:loop, iters, len}
      "add" -> :add
      "sub" -> :sub
      "mul" -> :mul
      "div" -> :div
      "get_start" -> :get_start
      "get_end" -> :get_end
      other -> other
    end)
  end
end
