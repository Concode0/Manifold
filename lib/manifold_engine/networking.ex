defmodule ManifoldEngine.Networking do
  @moduledoc "TCP orchestration for task execution, mitosis, and routing."
  use GenServer
  alias ManifoldEngine.{Node, Native, Router, Mitosis, LedgerSupervisor, Ledger}

  def name(port), do: :"Networking_#{port}"

  def start_link(opts) do
    port = opts[:port]
    GenServer.start_link(__MODULE__, opts, name: name(port))
  end

  @impl true
  def init(opts) do
    port = opts[:port]
    # Small delay to ensure Node state is ready
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    IO.puts "[NETWORKING] Listening on #{port}"
    Task.start_link(fn -> accept_loop(socket, port) end)
    {:ok, %{socket: socket, port: port}}
  end

  defp accept_loop(listen, port) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        Task.start(fn -> serve(client, port) end)
        accept_loop(listen, port)
      _ -> :ok
    end
  end

  defp serve(socket, port) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        case Jason.decode(data, keys: :atoms) do
          {:ok, %{type: "gossip", payload: p}} -> Node.record_peer_state(port, p)
          {:ok, %{type: "join", payload: p}} -> Node.record_peer_state(port, p)
          {:ok, %{type: "task", payload: p}} -> handle_task(p, port)
          {:ok, %{type: "result", payload: p}} -> handle_result(p)
          _ -> :ok
        end
        :gen_tcp.close(socket)
      _ -> :ok
    end
  end

  defp handle_task(payload, port) do
    task = struct(ManifoldEngine.Task, payload)
    task = %{task | program: ManifoldEngine.Task.normalize_program(task.program)}
    node = Node.get_state(port)
    
    case Mitosis.split_if_needed(task, port) do
      {job_id, shards} ->
        LedgerSupervisor.start_ledger([job_id: job_id, original_task_id: task.id, 
                                       total_shards: length(shards), return_addr: task.return_addr])
        Enum.each(shards, fn {s, peer} -> 
          if peer, do: Router.forward(s, peer), else: Task.start(fn -> execute_and_report(s, port) end) 
        end)

      nil ->
        if (node.current_load / node.capacity) > 0.8 do
           case Router.best_neighbor(task.req, port) do
              {peer, _} -> Router.forward(task, peer)
              nil -> Task.start(fn -> execute_and_report(task, port) end)
           end
        else
           Task.start(fn -> execute_and_report(task, port) end)
        end
    end
  end

  defp execute_and_report(task, port) do
    Node.update_load(port, 1.0)
    result = Native.execute_task(task.program, task.start || 0.0, task.end || 0.0)
    Node.update_load(port, -1.0)
    if task.parent_job_id, do: Ledger.report_result(task.parent_job_id, result), else: send_result_back(task.return_addr, task.id, result)
  end

  defp send_result_back(nil, _, _), do: :ok
  defp send_result_back({host, port}, tid, res) do
    packet = %{type: "result", payload: %{task_id: tid, result: res}}
    try do
      {:ok, s} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 2000)
      :gen_tcp.send(s, Jason.encode!(packet))
      :gen_tcp.close(s)
    rescue _ -> :ok end
  end

  defp handle_result(%{parent_job_id: jid, result: r}) when not is_nil(jid), do: Ledger.report_result(jid, r)
  defp handle_result(p), do: if(Map.has_key?(p, :parent_job_id), do: Ledger.report_result(p.parent_job_id, p.result), else: IO.puts("[NETWORKING] Final: #{p.result}"))
end
