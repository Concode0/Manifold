defmodule ManifoldEngine.Client do
  @moduledoc """
  Client for submitting tasks to the Manifold cluster.
  """

  def submit(task, target_host, target_port) do
    packet = %{type: "task", payload: task}
    IO.puts "[CLIENT] Submitting task #{task.id} to #{target_port}..."
    
    case :gen_tcp.connect(String.to_charlist(target_host), target_port, [:binary, active: false], 5000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, Jason.encode!(packet))
        :gen_tcp.close(socket)
        IO.puts "[CLIENT] Task submitted successfully."
      {:error, reason} ->
        IO.puts "[CLIENT] Failed to submit task: #{inspect(reason)}"
    end
  end

  @doc """
  Starts a listener to await results.
  """
  def listen(port) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    IO.puts "[CLIENT] Listening for results on port #{port}..."
    
    spawn(fn ->
      {:ok, client_socket} = :gen_tcp.accept(socket)
      case :gen_tcp.recv(client_socket, 0) do
        {:ok, data} ->
          case Jason.decode(data, keys: :atoms) do
            {:ok, %{type: "result", payload: payload}} ->
              IO.puts "

[CLIENT] RECEIVED FINAL AGGREGATED RESULT:"
              IO.inspect(payload.result)
            _ -> :ok
          end
        _ -> :ok
      end
      :gen_tcp.close(client_socket)
    end)
  end
end
