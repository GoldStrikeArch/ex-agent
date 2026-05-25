defmodule Network.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Network.TaskSupervisor},
      {DynamicSupervisor, name: Network.WebSocket.ConnectionSupervisor, strategy: :one_for_one},
      {Network.WebSocket.SessionPool, name: Network.WebSocket.SessionPool}
    ]

    opts = [strategy: :one_for_one, name: Network.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
