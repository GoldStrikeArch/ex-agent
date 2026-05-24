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

  def render({:agent_started, _session_id}) do
    []
  end

  def render({:agent_finished, _session_id}) do
    []
  end

  def render({:turn_started, _turn_id}) do
    []
  end

  def render({:turn_finished, _turn_id, _summary}) do
    []
  end

  def render({:message_started, _message_id, :user}) do
    []
  end

  def render({:message_started, _message_id, :assistant}) do
    "assistant> "
  end

  def render({:message_started, _message_id, role}) do
    [Atom.to_string(role), "> "]
  end

  def render({:message_delta, _message_id, text}) do
    text
  end

  def render({:message_finished, %{role: :user, content: text}}) do
    ["user> ", text, "\n"]
  end

  def render({:message_finished, %{role: :assistant}}) do
    "\n"
  end

  def render({:message_finished, %{role: role, content: text}}) do
    [Atom.to_string(role), "> ", text, "\n"]
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
    ["tool> ", name, " started\n"]
  end

  def render({:tool_output, _tool_call_id, chunk}) do
    ["tool output> ", chunk, "\n"]
  end

  def render({:tool_finished, _tool_call_id, status, summary}) do
    ["tool> finished ", inspect(status), " ", to_string(summary), "\n"]
  end

  def render({:batch_started, batch_id, count}) do
    ["batch> ", batch_id, " started ", Integer.to_string(count), " calls\n"]
  end

  def render({:batch_finished, batch_id, status}) do
    ["batch> ", batch_id, " finished ", inspect(status), "\n"]
  end

  def render({:edit_preview, edit_id, file_path, diff}) do
    ["edit> ", edit_id, " preview ", file_path, "\n", diff, "\n"]
  end

  def render({:edit_applied, edit_id, file_path}) do
    ["edit> ", edit_id, " applied ", file_path, "\n"]
  end

  def render({:validation_started, command}) do
    ["validation> ", command, " started\n"]
  end

  def render({:validation_finished, command, exit_status, summary}) do
    [
      "validation> ",
      command,
      " finished ",
      Integer.to_string(exit_status),
      " ",
      summary,
      "\n"
    ]
  end

  def render({:permission_requested, request_id, action}) do
    ["permission> ", request_id, " requested ", inspect(action), "\n"]
  end

  def render({:permission_resolved, request_id, decision}) do
    ["permission> ", request_id, " resolved ", inspect(decision), "\n"]
  end

  def render({:error, scope, reason}) do
    ["error ", inspect(scope), " ", inspect(reason), "\n"]
  end

  def render(event) do
    [inspect(event), "\n"]
  end
end
