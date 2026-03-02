# Run with: mix run test_nif.exs
alias ManifoldEngine.Native

IO.puts "--- Testing Geometric Distance ---"
# Features: [Cap=10, Mem=10], Req: [Cap=5, Mem=5], Load: 0, Capacity: 10, Trust: 1.0, Latency: 1.0
dist = Native.geometric_distance([10.0, 10.0], [5.0, 5.0], 0.0, 10.0, 1.0, 1.0)
IO.puts "Distance: #{dist}"

IO.puts "
--- Testing VM & Estimator ---"
# Program: Push(10), Push(20), Add
program = [
  {:push, 10.0},
  {:push, 20.0},
  :add
]

est = Native.estimate_task(program, 0.0, 0.0)
IO.inspect est, label: "Estimation"

result = Native.execute_task(program, 0.0, 0.0)
IO.puts "Result: #{result}"

IO.puts "
--- Testing Loops ---"
# Loop 5 times: Push 1
loop_program = [
  {:loop, 5, 1},
  {:push, 1.0}
]

est_loop = Native.estimate_task(loop_program, 0.0, 0.0)
IO.inspect est_loop, label: "Loop Estimation"

# Note: execute_task returns the last value on stack. 
# Our loop implementation pushes result of body to stack.
result_loop = Native.execute_task(loop_program, 0.0, 0.0)
IO.puts "Loop Result (last value): #{result_loop}"
