defmodule ManifoldEngine.Mitosis do
  @moduledoc """
  The task analysis and sharding engine.
  
  Determines if a task is computationally heavy enough to be split (mitosis)
  and calculates proportional work-ranges for candidate nodes.
  """
  alias ManifoldEngine.{Native, Router}

  @doc """
  Analyzes a task and performs proportional sharding if it exceeds the mitosis threshold.
  Returns {job_id, list_of_shards, shard_ids} or nil.
  """
  def split_if_needed(task, local_port) do
    if task.is_subtask do
      nil
    else
      # Stage 1: Static instruction analysis (offloaded to Rust data plane)
      estimation = Native.estimate_task(task.program, task.start || 0.0, task.end || 0.0)
      
      if estimation.recommended_shards > 1 do
        parent_job_id = task.id <> "_job_" <> to_string(:erlang.unique_integer([:positive]))
        start_val = task.start || 0.0
        end_val = task.end || 0.0
        total_range = end_val - start_val
        
        # Stage 2: Candidate selection via Minkowski geometry
        candidates = Router.best_candidates(task.req, local_port, estimation.recommended_shards)
        
        if length(candidates) == 0 do
          nil
        else
          # Stage 3: Proportional heterogeneous allocation
          # Shards are sized relative to the node's individual capacity.
          total_capacity = Enum.reduce(candidates, 0.0, fn {p, _}, acc -> acc + (p.capacity || 1.0) end)
          parent_addr = {"127.0.0.1", local_port}

          {_, shards} = Enum.reduce(candidates, {start_val, []}, fn {peer, _}, {current_s, acc_shards} ->
            portion = (peer.capacity / total_capacity) * total_range
            next_e = min(end_val, current_s + portion)
            
            shard_id = "#{task.id}_shard_#{length(acc_shards)}"
            shard = %{task | id: shard_id, parent_job_id: parent_job_id, start: current_s, end: next_e, is_subtask: true, return_addr: parent_addr}
            
            {next_e, [{shard, peer} | acc_shards]}
          end)

          shard_ids = Enum.map(shards, fn {shard, _} -> shard.id end)
          {parent_job_id, shards, shard_ids}
        end
      else
        nil
      end
    end
  end
end
