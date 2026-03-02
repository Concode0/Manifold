defmodule ManifoldEngine.Native do
  use Rustler, otp_app: :manifold_engine, crate: "manifold_rust"

  def geometric_distance(_node_features, _task_req, _current_load, _capacity, _trust_index, _latency),
    do: :erlang.nif_error(:nif_not_loaded)

  def estimate_task(_program, _start, _end), do: :erlang.nif_error(:nif_not_loaded)
  def execute_task(_program, _start, _end), do: :erlang.nif_error(:nif_not_loaded)
end
