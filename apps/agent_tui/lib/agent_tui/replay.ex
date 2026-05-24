defmodule AgentTui.Replay do
  @moduledoc """
  Replays JSONL event logs through the text renderer.
  """

  @doc """
  Renders a JSONL event log to an IO device.
  """
  @spec render_file(Path.t(), keyword()) :: :ok | {:error, term()}
  def render_file(path, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)

    with {:ok, events} <- AgentCore.EventLog.read_events(path) do
      Enum.each(events, &IO.write(io, AgentTui.TextRenderer.render(&1)))
      :ok
    end
  end
end
