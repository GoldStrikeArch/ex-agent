defmodule AgentTui.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: AgentTui.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: AgentTui.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
