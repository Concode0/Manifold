defmodule ManifoldEngine.Task do
  @moduledoc "Represents a Deterministic Functional Task."
  @derive Jason.Encoder
  defstruct [
    :id, :program, :req, :effort, :start, :end, :return_addr, :parent_job_id, :is_subtask,
    status: :pending
  ]

  @doc "Converts JSON-decoded bytecode back to Rustler-compatible variants."
  def normalize_program(nil), do: []
  def normalize_program(program) when is_list(program) do
    Enum.map(program, fn
      ["push", val] -> {:push, val / 1.0} # Ensure float
      ["load", addr] -> {:load, addr}
      ["store", addr] -> {:store, addr}
      ["loop", iters, len] -> {:loop, iters, len}
      "add" -> :add
      "sub" -> :sub
      "mul" -> :mul
      "div" -> :div
      "get_start" -> :get_start
      "get_end" -> :get_end
      # Fallback for already correct formats or unexpected ones
      other -> other
    end)
  end
end
