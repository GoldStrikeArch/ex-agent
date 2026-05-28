defmodule Structural.MixProject do
  use Mix.Project

  def project do
    [
      app: :structural,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Structural.Application, []}
    ]
  end

  defp deps do
    [
      {:core, in_umbrella: true},
      {:exqlite, "~> 0.36"},
      {:tree_sitter_language_pack, "1.9.0-rc.12"}
    ]
  end
end
