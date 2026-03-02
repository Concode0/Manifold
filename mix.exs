defmodule ManifoldEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_engine,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ManifoldEngine.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
    {:ra, ">= 2.0.0"},
    {:rustler, "~> 0.37.0"},
    {:jason, "~> 1.4"},
    {:nx, "~> 0.6"}
    ]
  end
end
