defmodule ManifoldEngine.Networking do
  @moduledoc """
  The communication backbone of the Manifold Node.
  
  Handles binary term transmission via TCP with length-prefixed framing.
  Orchestrates incoming tasks by deciding between local execution, 
  forwarding (routing), or sharding (mitosis).
  """
  use GenServer
  alias ManifoldEngine.{Node, Native, Router, Mitosis, LedgerSupervisor, Ledger}
  require Logger

  def name(port), do: :"Networking_#{port}"

  def start_link(opts) do
    port = opts[:port]
    GenServer.start_link(__MODULE__, opts, name: name(port))
  end

  @impl true
  def init(opts) do
    port = opts[:port]

    # Switch to packet: 4 for robust ETF transport
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: 4, active: false, reuseaddr: true])
    IO.puts "[NETWORKING] Listening on #{port}"
    Elixir.Task.start_link(fn -> accept_loop(socket, port) end)
    {:ok, %{socket: socket, port: port}}
  end

  defp accept_loop(listen, port) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        Elixir.Task.start(fn -> serve(client, port) end)
        accept_loop(listen, port)
      _ -> :ok
    end
  end

  defp serve(socket, port) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        try do
          case :erlang.binary_to_term(data) do
            %{type: "gossip", payload: p} -> Node.record_peer_state(port, p)
            %{type: "join", payload: p} -> Node.record_peer_state(port, p)
            %{type: "task", payload: p} -> handle_task(p, port)
            %{type: "result", payload: p} -> handle_result(p)
            _ -> :ok
          end
        rescue
          _ -> :ok
        end
        :gen_tcp.close(socket)
      _ -> :ok
    end
  end

  # Task lifecycle logic
  defp handle_task(payload, port) do
    task = if is_struct(payload, ManifoldEngine.Task), do: payload, else: struct(ManifoldEngine.Task, payload)
    task = %{task | program: ManifoldEngine.Task.normalize_program(task.program)}
    
    case Mitosis.split_if_needed(task, port) do
      {job_id, shards, shard_ids} ->
        # Mitosis path: task is heavy enough to split
        LedgerSupervisor.start_ledger([job_id: job_id, original_task_id: task.id, 
                                       total_shards: length(shards), shard_ids: shard_ids,
                                       return_addr: task.return_addr, reducer: task.reducer,
                                       local_port: port])
        Enum.each(shards, fn {s, peer} -> 
          if peer, do: Router.forward(s, peer), else: Elixir.Task.start(fn -> execute_and_report(s, port) end) 
        end)

      nil ->
        # Routing path: task is small, decide if local or forward
        node = Node.get_state(port)
        avg_load = calculate_avg_cluster_load(node)
        load_ratio = node.current_load / node.capacity
        
        # Simple threshold for forwarding to less busy nodes
        if load_ratio > (avg_load + 0.2) do
           case Router.best_candidates(task.req, port, 1) do
              [{peer, _}] -> Router.forward(task, peer)
              [] -> Elixir.Task.start(fn -> execute_and_report(task, port) end)
           end
        else
           Elixir.Task.start(fn -> execute_and_report(task, port) end)
        end
    end
  end

  defp calculate_avg_cluster_load(node) do
    peers = Map.values(node.peers)
    if length(peers) == 0 do
      0.0
    else
      total_ratio = Enum.reduce(peers, 0.0, fn p, acc -> 
        acc + (p.current_load / (p.capacity || 1.0))
      end)
      total_ratio / length(peers)
    end
  end

  defp execute_and_report(task, port) do
    Node.update_load(port, 1.0)
    result = Native.execute_task(task.program, task.start || 0.0, task.end || 0.0)
    Node.update_load(port, -1.0)
    
    if task.parent_job_id do
      # Shard reporting: try local ledger first (source case)
      case Ledger.report_result(task.parent_job_id, task.id, result) do
        :ok -> :ok
        :error -> 
          # Remote reporting: send result back to the specific ledger node
          if task.return_addr != {"127.0.0.1", port} do
            send_result_back(task.return_addr, task.id, result, task.parent_job_id)
          else
            :ok
          end
      end
    else
      # Independent task: send directly back to client
      send_result_back(task.return_addr, task.id, result, nil)
    end
  end

  defp send_result_back(nil, _, _, _), do: :ok
  defp send_result_back({host, port}, tid, res, jid) do
    packet = %{type: "result", payload: %{task_id: tid, result: res, parent_job_id: jid}}
    try do
      # Consistent packet: 4 framing
      {:ok, s} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: 4, active: false], 2000)
      :gen_tcp.send(s, :erlang.term_to_binary(packet))
      :gen_tcp.close(s)
    rescue
      _ -> :ok
    end
  end

  defp handle_result(%{task_id: tid, parent_job_id: jid, result: r}) when not is_nil(jid) do
    Ledger.report_result(jid, tid, r)
  end
  defp handle_result(%{result: _r}) do
    :ok
  end
end
