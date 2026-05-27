defmodule Core.TurnTaskSupervisor do
  @moduledoc """
  Named `Task.Supervisor` that owns active turn tasks.

  Each `Core.AgentSession` turn runs as a task here so the model/tool loop lives
  outside the session GenServer. Terminating a turn task cancels the turn (and,
  through the per-turn tool supervisor, its in-flight tool tasks) while keeping
  the session process alive.
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
