defmodule AgentApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: AgentApp.CLI],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AgentApp.Application, []}
    ]
  end

  defp deps do
    [
      {:core, in_umbrella: true},
      {:llm, in_umbrella: true},
      {:tui, in_umbrella: true}
    ]
  end
end
