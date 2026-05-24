defmodule AgentCore.ToolTaskSupervisor do
  @moduledoc """
  Named `Task.Supervisor` used for future concurrent tool execution.
  """

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task.Supervisor, :start_link, [[name: __MODULE__]]},
      type: :supervisor
    }
  end
end
