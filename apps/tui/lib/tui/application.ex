defmodule Tui.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Tui.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Tui.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
