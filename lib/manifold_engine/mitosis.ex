defmodule ManifoldEngine.Mitosis do
  @moduledoc "Handles task splitting based on effort estimation."
  alias ManifoldEngine.{Native, Router}

  @doc "Analyzes task effort and splits into shards if threshold exceeded."
  def split_if_needed(task, local_port) do
    if task.is_subtask do
      nil
    else
      estimation = Native.estimate_task(task.program, task.start || 0.0, task.end || 0.0)
      
      if estimation.recommended_shards > 1 do
        parent_job_id = task.id <> "_job_" <> to_string(:erlang.unique_integer([:positive]))
        start_val = task.start || 0.0
        end_val = task.end || 0.0
        step = (end_val - start_val) / estimation.recommended_shards
        
        # Get top candidates once per mitosis event
        candidates = Router.best_candidates(task.req, local_port, 3)

        shards = Enum.map(0..(estimation.recommended_shards - 1), fn i ->
          s = start_val + (i * step)
          e = if i == estimation.recommended_shards - 1, do: end_val, else: start_val + ((i + 1) * step)
          shard = %{task | id: "#{task.id}_shard_#{i}", parent_job_id: parent_job_id, start: s, end: e, is_subtask: true}
          
          # Randomly pick from candidates to distribute shards during same gossip window
          peer = if length(candidates) > 0 do
            {p, _} = Enum.random(candidates)
            p
          else
            nil
          end
          
          {shard, peer}
        end)
        {parent_job_id, shards}
      else
        nil
      end
    end
  end
end
