defmodule Kelescope.Boot.MixProject do
  use Mix.Project

  def project do
    [
      app: :kelescope_boot,
      version: "1.0.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Kelescope.Boot.Application, []},
      extra_applications: [:logger, :runtime_tools],
      env: [build: System.get_env("KELESCOPE_BUILD_VERSION", "dev")]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.12"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end
end
