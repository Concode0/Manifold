defmodule ManifoldEngineTest do
  use ExUnit.Case
  doctest ManifoldEngine

  test "greets the world" do
    assert ManifoldEngine.hello() == :world
  end
end
