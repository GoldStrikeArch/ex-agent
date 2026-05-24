defmodule AgentTui.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_tui,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: AgentTui.CLI],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AgentTui.Application, []}
    ]
  end

  defp deps do
    [
      {:agent_core, in_umbrella: true},
      {:term_ui, "~> 1.0.0-rc"}
    ]
  end
end
