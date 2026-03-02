# Run with: mix run test_dsm.exs
alias ManifoldEngine.DSM

IO.puts "--- Starting Raft DSM Cluster ---"
Application.ensure_all_started(:ra)
:ra.start()

node_id = :manifold_test_node
server_id = {node_id, Node.self()}
members = [server_id]

# Start a single-node Raft cluster for testing
{:ok, _, _} = DSM.start_server(node_id, members)

# Wait a moment for Raft leader election (even in single node, it takes a beat)
Process.sleep(1000)

IO.puts "
--- Testing PUT and GET ---"
:ok = DSM.put(server_id, "vault", 100)
{:ok, val} = DSM.get(server_id, "vault")
IO.puts "Vault value: #{val}"

IO.puts "
--- Testing Compare-And-Swap (CAS) ---"
# Successful CAS
:ok = DSM.cas(server_id, "vault", 100, 200)
{:ok, new_val} = DSM.get(server_id, "vault")
IO.puts "Vault value after successful CAS: #{new_val}"

# Failed CAS (wrong old value)
error = DSM.cas(server_id, "vault", 100, 300)
IO.inspect error, label: "CAS with wrong old_value result"

{:ok, final_val} = DSM.get(server_id, "vault")
IO.puts "Vault value remains: #{final_val}"

IO.puts "
--- Test Complete ---"
