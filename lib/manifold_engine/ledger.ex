defmodule ManifoldEngine.Ledger do
  @moduledoc "Aggregates shards from a split mitosis job."
  use GenServer

  def start_link(opts) do
    job_id = opts[:job_id]
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {ManifoldEngine.LedgerRegistry, job_id}})
  end

  @impl true
  def init(opts) do
    {:ok, %{job_id: opts[:job_id], task_id: opts[:original_task_id], total: opts[:total_shards], 
            results: [], return_addr: opts[:return_addr]}}
  end

  def report_result(job_id, result) do
    case Registry.lookup(ManifoldEngine.LedgerRegistry, job_id) do
      [{pid, _}] -> GenServer.cast(pid, {:result, result})
      [] -> :error
    end
  end

  @impl true
  def handle_cast({:result, result}, state) do
    new_results = [result | state.results]
    
    if length(new_results) == state.total do
      # Ledger Completion: Final aggregation of deterministic shard results.
      final_result = Enum.sum(new_results)
      send_result_back(state.return_addr, state.task_id, final_result)
      {:stop, :normal, state}
    else
      {:noreply, %{state | results: new_results}}
    end
  end

  defp send_result_back(nil, _tid, _res), do: :ok
  defp send_result_back({host, port}, task_id, result) do
    packet = %{type: "result", payload: %{task_id: task_id, result: result}}
    Task.start(fn ->
      try do
        {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 2000)
        :gen_tcp.send(socket, Jason.encode!(packet))
        :gen_tcp.close(socket)
      rescue _ -> :ok end
    end)
  end
end

defmodule ManifoldEngine.LedgerSupervisor do
  @moduledoc "Dynamic supervisor for mitosis aggregation ledgers."
  use DynamicSupervisor

  def start_link(init_arg), do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
  def start_ledger(opts), do: DynamicSupervisor.start_child(__MODULE__, {ManifoldEngine.Ledger, opts})
end
