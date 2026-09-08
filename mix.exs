defmodule Kelescope.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: [],
      releases: releases()
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp releases do
    [
      kelescope: [
        version: "1.0.0",
        applications: [kelescope_boot: :permanent],
        include_executables_for: [:unix]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["do --app kelescope_core setup"],
      "assets.build": ["do --app kelescope_core assets.build"],
      "assets.deploy": ["do --app kelescope_core assets.deploy"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
