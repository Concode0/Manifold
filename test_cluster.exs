# Run with: mix run test_cluster.exs

# Mock Join logic to bootstrap the cluster
defmodule Bootstrapper do
  def join(target_port, self_state) do
    payload = %{
      id: self_state.id,
      host: self_state.host,
      port: self_state.port,
      capacity: self_state.capacity,
      memory: self_state.memory,
      current_load: self_state.current_load,
      trust_index: self_state.trust_index
    }
    packet = Jason.encode!(%{type: "join", payload: payload})
    
    try do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", target_port, [:binary, active: false], 1000)
      :gen_tcp.send(socket, packet)
      :gen_tcp.close(socket)
    rescue
      _ -> IO.puts "Failed to join #{target_port}"
    end
  end
end

# Since we are running in one BEAM instance for this test, we have a name conflict
# with GenServers. In a real scenario, these would be separate OS processes.
# For this test, let's just start one node and see it listen.

port = String.to_integer(System.get_env("PORT") || "9001")
IO.puts "--- Starting Node on Port #{port} ---"

# Application.start(:manifold_engine) is called automatically by mix run

# Wait and see gossip/topology output
Process.sleep(15000)
