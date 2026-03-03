defmodule ManifoldEngine.IntegrationTest do
  use ExUnit.Case
  alias ManifoldEngine.{Application, Client}

  setup_all do
    Elixir.Application.ensure_all_started(:ra)
    :ok
  end

  defp start_result_listener(port, parent) do
    {:ok, listen_socket} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    Elixir.Task.start(fn ->
      case :gen_tcp.accept(listen_socket) do
        {:ok, socket} ->
          case :gen_tcp.recv(socket, 0) do
            {:ok, data} ->
              case :erlang.binary_to_term(data) do
                %{type: "result", payload: %{result: res}} -> send(parent, {:task_result, res})
                _ -> :ok
              end
            _ -> :ok
          end
          :gen_tcp.close(socket)
        _ -> :ok
      end
      :gen_tcp.close(listen_socket)
    end)
  end

  test "end-to-end task execution and aggregation" do
    port = 18101
    callback_port = 18102
    
    Application.start_node(port, 10.0, 10.0)
    Process.sleep(500)

    start_result_listener(callback_port, self())

    program = [{:push, 10.0}, {:push, 20.0}, :add]
    task = %ManifoldEngine.Task{
      id: "integration_task",
      program: program,
      req: [1.0, 1.0],
      return_addr: {"127.0.0.1", callback_port}
    }

    Client.submit(task, "127.0.0.1", port)
    assert_receive {:task_result, 30.0}, 5000
  end

  test "task mitosis and proportional range splitting" do
    node1_port = 18103
    node2_port = 18104
    node3_port = 18106
    callback_port = 18105
    
    Application.start_node(node1_port, 10.0, 10.0)
    Application.start_node(node2_port, 20.0, 20.0)
    Application.start_node(node3_port, 10.0, 10.0)
    Process.sleep(500)

    ManifoldEngine.Node.update_neighbors(node1_port, [node2_port, node3_port])
    ManifoldEngine.Node.record_peer_state(node1_port, %{id: node2_port, host: "127.0.0.1", port: node2_port, capacity: 20.0, memory: 20.0, current_load: 0.0})
    ManifoldEngine.Node.record_peer_state(node1_port, %{id: node3_port, host: "127.0.0.1", port: node3_port, capacity: 10.0, memory: 10.0, current_load: 0.0})

    Process.sleep(500)
    start_result_listener(callback_port, self())

    program = [{:loop, 100, 3}, :get_start, :get_end, :add]
    task = %ManifoldEngine.Task{
      id: "mitosis_task",
      program: program,
      req: [5.0, 5.0],
      start: 0.0,
      end: 100.0,
      return_addr: {"127.0.0.1", callback_port},
      reducer: :sum
    }

    Client.submit(task, "127.0.0.1", node1_port)
    assert_receive {:task_result, res}, 10000
    assert_in_delta res, 166.66, 1.0
  end

  test "mitosis with collect reducer" do
    node1_port = 18201
    node2_port = 18202
    node3_port = 18203
    callback_port = 18204
    
    Application.start_node(node1_port, 10.0, 10.0)
    Application.start_node(node2_port, 10.0, 10.0)
    Application.start_node(node3_port, 10.0, 10.0)
    Process.sleep(500)

    ManifoldEngine.Node.update_neighbors(node1_port, [node2_port, node3_port])
    ManifoldEngine.Node.record_peer_state(node1_port, %{id: node2_port, host: "127.0.0.1", port: node2_port, capacity: 10.0, memory: 10.0, current_load: 0.0})
    ManifoldEngine.Node.record_peer_state(node1_port, %{id: node3_port, host: "127.0.0.1", port: node3_port, capacity: 10.0, memory: 10.0, current_load: 0.0})

    Process.sleep(500)
    start_result_listener(callback_port, self())

    program = [{:loop, 100, 1}, {:push, 1.0}]
    task = %ManifoldEngine.Task{
      id: "collect_task",
      program: program,
      req: [5.0, 5.0],
      start: 0.0,
      end: 100.0,
      return_addr: {"127.0.0.1", callback_port},
      reducer: :collect
    }

    Client.submit(task, "127.0.0.1", node1_port)
    assert_receive {:task_result, results}, 10000
    assert is_list(results)
    assert length(results) == 2
    assert Enum.all?(results, fn r -> r == 1.0 end)
  end
end
