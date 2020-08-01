defmodule DevRandom.MixProject do
  use Mix.Project

  def project do
    [
      app: :dev_random_ex,
      version: "0.4.0",
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
      {:quantum, "~> 3.0"},
      {:timex, "~> 3.0"},
      {:distillery, "~> 2.0", runtime: false},
      {:pid_file, "~> 0.1.0"},
      {:jason, "~> 1.1"},
      {:sweet_xml, "~> 0.3"},
      {:swoosh, "~> 1.0"},
      {:gen_smtp, "~> 0.13"},
      {:external_service, "~> 1.0"},
      {:phash, "~> 0.1"}
    ]
  end
end
