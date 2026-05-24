defmodule AgentTui.TextRenderer do
  @moduledoc """
  Converts core events into append-only terminal text.
  """

  @doc """
  Renders one event as iodata.
  """
  @spec render(tuple()) :: iodata()
  def render({:session_started, %{session_id: session_id}}) do
    ["session started ", session_id, "\n"]
  end

  def render({:user_message, text}) do
    ["user> ", text, "\n"]
  end

  def render({:assistant_message_started, _message_id}) do
    "assistant> "
  end

  def render({:assistant_delta, _message_id, text}) do
    text
  end

  def render({:assistant_message_finished, _message_id}) do
    "\n"
  end

  def render({:tool_started, _tool_call_id, name, _args}) do
    ["tool started ", name, "\n"]
  end

  def render({:tool_finished, _tool_call_id, status, summary}) do
    ["tool finished ", inspect(status), " ", to_string(summary), "\n"]
  end

  def render({:error, scope, reason}) do
    ["error ", inspect(scope), " ", inspect(reason), "\n"]
  end

  def render(event) do
    [inspect(event), "\n"]
  end
end
