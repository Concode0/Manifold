defmodule ManifoldEngine.Ledger do
  @moduledoc """
  The result aggregation and synchronization point for sharded tasks.
  
  Maintains the state of pending shards for a specific Job and applies 
  a reduction function once all results are collected.
  """
  use GenServer
  require Logger

  @default_timeout 30_000 
  @max_retries 5
  @initial_backoff 500

  def start_link(opts) do
    job_id = opts[:job_id]
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {ManifoldEngine.LedgerRegistry, job_id}})
  end

  @impl true
  def init(opts) do
    job_id = opts[:job_id]
    local_port = opts[:local_port]
    # Back-pressure: track active ledgers to distort geometry for new incoming tasks
    if local_port, do: ManifoldEngine.Node.update_ledger_pressure(local_port, 1)

    pending_shards = MapSet.new(opts[:shard_ids] || [])
    timeout = opts[:timeout] || @default_timeout
    timer_ref = Process.send_after(self(), :job_timeout, timeout)

    {:ok, %{
      job_id: job_id, 
      task_id: opts[:original_task_id], 
      total: opts[:total_shards], 
      pending: pending_shards,
      results: [], 
      return_addr: opts[:return_addr],
      reducer: opts[:reducer] || :sum,
      timeout: timeout,
      timer_ref: timer_ref,
      local_port: local_port,
      status: :active
    }}
  end

  @doc "Reports a shard result to the specific Ledger process managing the job."
  def report_result(job_id, shard_id, result) do
    case Registry.lookup(ManifoldEngine.LedgerRegistry, job_id) do
      [{pid, _}] -> GenServer.call(pid, {:result, shard_id, result})
      [] -> :error
    end
  end

  @impl true
  def handle_call({:result, shard_id, result}, _from, %{status: :active} = state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    new_timer_ref = Process.send_after(self(), :job_timeout, state.timeout)

    new_pending = MapSet.delete(state.pending, shard_id)
    new_results = [result | state.results]
    
    if MapSet.size(new_pending) == 0 do
      # Completion path: all shards received
      Process.cancel_timer(new_timer_ref)
      if state.local_port, do: ManifoldEngine.Node.update_ledger_pressure(state.local_port, -1)
      
      final_result = apply_reducer(state.reducer, new_results)
      send_result_back(state.return_addr, state.task_id, final_result, state.job_id)
      
      # Stop immediately after aggregation to release resources
      {:stop, :normal, :ok, %{state | results: new_results, pending: new_pending, status: :completed, timer_ref: nil}}
    else
      {:reply, :ok, %{state | results: new_results, pending: new_pending, timer_ref: new_timer_ref}}
    end
  end

  def handle_call({:result, _shard_id, _result}, _from, state) do
    {:reply, :error_expired, state}
  end

  defp apply_reducer(:sum, results), do: Enum.sum(results)
  defp apply_reducer(:min, results), do: Enum.min(results)
  defp apply_reducer(:max, results), do: Enum.max(results)
  defp apply_reducer(:collect, results), do: results
  defp apply_reducer(_, results), do: Enum.sum(results)

  @impl true
  def handle_info(:job_timeout, %{status: :active} = state) do
    if state.local_port, do: ManifoldEngine.Node.update_ledger_pressure(state.local_port, -1)
    send_failure_back(state.return_addr, state.task_id, :timeout)
    {:stop, :normal, state}
  end

  def handle_info(:job_timeout, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:gen_event, _}, state), do: {:noreply, state}

  defp send_result_back(nil, _tid, _res, _jid), do: :ok
  defp send_result_back({host, port}, task_id, result, job_id) do
    packet = %{type: "result", payload: %{task_id: task_id, result: result, parent_job_id: job_id}}
    spawn_retry_task(host, port, packet)
  end

  defp send_failure_back(nil, _tid, _reason), do: :ok
  defp send_failure_back({host, port}, task_id, reason) do
    packet = %{type: "error", payload: %{task_id: task_id, reason: reason}}
    spawn_retry_task(host, port, packet)
  end

  defp spawn_retry_task(host, port, packet) do
    Task.start(fn ->
      do_send_with_retry(host, port, packet, @max_retries, @initial_backoff)
    end)
  end

  defp do_send_with_retry(host, port, packet, retries, backoff) do
    try do
      {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: 4, active: false], 2000)
      :gen_tcp.send(socket, :erlang.term_to_binary(packet))
      :gen_tcp.close(socket)
    rescue
      _ ->
        if retries > 0 do
          Process.sleep(backoff)
          # Exponential backoff
          do_send_with_retry(host, port, packet, retries - 1, backoff * 2)
        else
          :ok
        end
    end
  end
end

defmodule ManifoldEngine.LedgerSupervisor do
  @moduledoc "Dynamic supervisor for lifecycle management of active Job Ledgers."
  use DynamicSupervisor

  def start_link(init_arg), do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
  def start_ledger(opts), do: DynamicSupervisor.start_child(__MODULE__, {ManifoldEngine.Ledger, opts})
end
