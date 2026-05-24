defmodule Tui.MixProject do
  use Mix.Project

  def project do
    [
      app: :tui,
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
      mod: {Tui.Application, []}
    ]
  end

  defp deps do
    [
      {:term_ui, "~> 1.0.0-rc"}
    ]
  end
end
