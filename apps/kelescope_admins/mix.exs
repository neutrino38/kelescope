defmodule Kelescope.Admins.MixProject do
  use Mix.Project

  def project do
    [
      app: :kelescope_admins,
      version: "1.0.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [build: System.get_env("KELESCOPE_BUILD_VERSION", "dev")]
    ]
  end

  defp deps do
    [{:kelescope_core, in_umbrella: true}]
  end
end
