defmodule Network.MixProject do
  use Mix.Project

  def project do
    [
      app: :network,
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
      mod: {Network.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5.18"},
      {:plug_cowboy, "~> 2.8"}
    ]
  end
end
