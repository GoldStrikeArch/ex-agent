defmodule AgentCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AgentCore.EventBus,
      AgentCore.FileLockManager,
      AgentCore.SessionSupervisor,
      AgentCore.ToolTaskSupervisor
    ]

    opts = [strategy: :one_for_one, name: AgentCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
