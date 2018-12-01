defmodule DevRandom.MixProject do
  use Mix.Project

  def project do
    [
      app: :dev_random_ex,
      version: "0.2.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :httpoison, :timex],
      mod: {DevRandom.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:httpoison, "~> 1.0"},
      {:poison, "~> 3.1"},
      {:quantum, "~> 2.2"},
      {:timex, "~> 3.0"},
      {:distillery, "~> 1.5", runtime: false},
      {:pid_file, "~> 0.1.0"}
    ]
  end
end
