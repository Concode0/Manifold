defmodule ManifoldEngine.NativeTest do
  use ExUnit.Case
  alias ManifoldEngine.Native

  test "geometric_distance calculation consistency" do
    dist = Native.geometric_distance([10.0, 10.0], [5.0, 5.0], 0.0, 10.0, 1.0, 1.0)
    assert is_float(dist)
    assert dist > 0
    
    # Distance should increase with load
    dist_high_load = Native.geometric_distance([10.0, 10.0], [5.0, 5.0], 8.0, 10.0, 1.0, 1.0)
    assert dist_high_load > dist
    
    # Distance should decrease with trust
    dist_low_trust = Native.geometric_distance([10.0, 10.0], [5.0, 5.0], 0.0, 10.0, 0.5, 1.0)
    assert dist_low_trust > dist
  end

  test "estimate_task returns reasonable effort" do
    program = [{:push, 10.0}, {:push, 20.0}, :add]
    est = Native.estimate_task(program, 0.0, 1.0)
    assert est.effort > 0
    assert est.recommended_shards >= 1
  end

  test "execute_task performs basic arithmetic" do
    program = [{:push, 10.0}, {:push, 20.0}, :add]
    assert Native.execute_task(program, 0.0, 0.0) == 30.0
    
    program = [{:push, 50.0}, {:push, 20.0}, :sub]
    assert Native.execute_task(program, 0.0, 0.0) == 30.0
    
    program = [{:push, 10.0}, {:push, 3.0}, :mul]
    assert Native.execute_task(program, 0.0, 0.0) == 30.0
    
    program = [{:push, 90.0}, {:push, 3.0}, :div]
    assert Native.execute_task(program, 0.0, 0.0) == 30.0
  end

  test "execute_task handles loops" do
    # Loop 10 times, push 1.0. Final value on stack should be 1.0
    program = [{:loop, 10, 1}, {:push, 1.0}]
    assert Native.execute_task(program, 0.0, 0.0) == 1.0
  end

  test "execute_task handles memory operations" do
    program = [{:push, 42.0}, {:store, 1}, {:load, 1}]
    assert Native.execute_task(program, 0.0, 0.0) == 42.0
  end
end
