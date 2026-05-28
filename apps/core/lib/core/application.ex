defmodule Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Core.EventBus
      ] ++
        event_log_children() ++
        [
          Core.FileLockManager,
          Core.SessionSupervisor,
          Core.TurnTaskSupervisor,
          Core.ToolTaskSupervisor
        ]

    opts = [strategy: :one_for_one, name: Core.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp event_log_children do
    if event_log_enabled?() do
      [
        {Core.EventLog, path: event_log_path(), name: Core.DefaultEventLog, required?: false}
      ]
    else
      []
    end
  end

  defp event_log_enabled? do
    case System.get_env("ELIXIR_AGENT_EVENT_LOG") do
      nil -> Keyword.get(event_log_config(), :enabled, true)
      value when value in ["0", "false", "FALSE", "off", "disabled"] -> false
      _value -> true
    end
  end

  defp event_log_path do
    Keyword.get_lazy(event_log_config(), :path, &Core.EventLog.default_path/0)
  end

  defp event_log_config do
    case Application.get_env(:core, :event_log, []) do
      config when is_list(config) -> config
      true -> [enabled: true]
      false -> [enabled: false]
      _config -> []
    end
  end
end
