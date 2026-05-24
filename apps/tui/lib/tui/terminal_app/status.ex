defmodule Tui.TerminalApp.Status do
  @moduledoc """
  Reduces agent events into compact, stateful UI status.
  """

  @type tool_state :: %{
          name: String.t(),
          args: map(),
          output_bytes: non_neg_integer()
        }

  @type batch_state :: %{
          count: non_neg_integer()
        }

  @type permission_state :: %{
          request_id: String.t(),
          status: :pending | :resolved,
          action: term(),
          decision: term() | nil
        }

  @type event_status :: :ok | :error | :cancelled | :timeout

  @type t :: %__MODULE__{
          active_batches: %{String.t() => batch_state()},
          active_tools: %{String.t() => tool_state()},
          current_turn: String.t() | nil,
          last_batch: {String.t(), event_status()} | nil,
          last_error: {atom(), term()} | nil,
          last_tool: {String.t(), String.t(), event_status(), term()} | nil,
          permission: permission_state() | nil,
          session_id: String.t() | nil,
          status: :idle | :running | :finished | :error
        }

  defstruct active_batches: %{},
            active_tools: %{},
            current_turn: nil,
            last_batch: nil,
            last_error: nil,
            last_tool: nil,
            permission: nil,
            session_id: nil,
            status: :idle

  @doc """
  Builds an idle status snapshot.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Applies one agent event to a status snapshot.
  """
  @spec reduce_event(t(), tuple()) :: t()
  def reduce_event(state, {:session_started, %{session_id: session_id}}) do
    %{state | session_id: session_id, status: :idle}
  end

  def reduce_event(state, {:agent_started, session_id}) do
    %{state | session_id: session_id, status: :running}
  end

  def reduce_event(state, {:agent_finished, _session_id}) do
    %{state | current_turn: nil, status: :finished}
  end

  def reduce_event(state, {:turn_started, turn_id}) do
    %{state | current_turn: turn_id, status: :running}
  end

  def reduce_event(state, {:turn_finished, turn_id, %{status: :ok}}) do
    clear_current_turn(state, turn_id, :finished)
  end

  def reduce_event(state, {:turn_finished, turn_id, %{status: :error} = summary}) do
    state
    |> clear_current_turn(turn_id, :error)
    |> Map.put(:last_error, {:turn, Map.get(summary, :reason, summary)})
  end

  def reduce_event(state, {:tool_started, call_id, name, args}) do
    tool = %{name: name, args: args, output_bytes: 0}
    %{state | active_tools: Map.put(state.active_tools, call_id, tool), status: :running}
  end

  def reduce_event(state, {:tool_output, call_id, chunk}) do
    active_tools =
      Map.update(
        state.active_tools,
        call_id,
        %{name: call_id, args: %{}, output_bytes: byte_size(chunk)},
        fn tool ->
          Map.update!(tool, :output_bytes, &(&1 + byte_size(chunk)))
        end
      )

    %{state | active_tools: active_tools}
  end

  def reduce_event(state, {:tool_finished, call_id, status, summary}) do
    {tool, active_tools} = Map.pop(state.active_tools, call_id)
    name = if tool, do: tool.name, else: call_id

    state
    |> Map.put(:active_tools, active_tools)
    |> Map.put(:last_tool, {call_id, name, status, summary})
    |> settle_status()
  end

  def reduce_event(state, {:batch_started, batch_id, count}) do
    batch = %{count: count}
    %{state | active_batches: Map.put(state.active_batches, batch_id, batch), status: :running}
  end

  def reduce_event(state, {:batch_finished, batch_id, status}) do
    state
    |> Map.put(:active_batches, Map.delete(state.active_batches, batch_id))
    |> Map.put(:last_batch, {batch_id, status})
    |> settle_status()
  end

  def reduce_event(state, {:permission_requested, request_id, action}) do
    permission = %{request_id: request_id, status: :pending, action: action, decision: nil}
    %{state | permission: permission}
  end

  def reduce_event(state, {:permission_resolved, request_id, decision}) do
    permission =
      case state.permission do
        %{request_id: ^request_id} = permission ->
          %{permission | status: :resolved, decision: decision}

        _other ->
          %{request_id: request_id, status: :resolved, action: nil, decision: decision}
      end

    %{state | permission: permission}
  end

  def reduce_event(state, {:error, scope, reason}) do
    %{state | last_error: {scope, reason}, status: :error}
  end

  def reduce_event(state, _event), do: state

  @doc """
  Renders one status line for the top of the screen.
  """
  @spec summary_line(t()) :: String.t()
  def summary_line(%__MODULE__{} = state) do
    [
      "agent: ",
      Atom.to_string(state.status),
      session_segment(state),
      turn_segment(state),
      " | tools ",
      Integer.to_string(map_size(state.active_tools)),
      " | batches ",
      Integer.to_string(map_size(state.active_batches)),
      permission_segment(state)
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Renders status panel lines for the `/status` command.
  """
  @spec panel_lines(t()) :: [String.t()]
  def panel_lines(%__MODULE__{} = state) do
    [
      summary_line(state),
      active_tools_line(state),
      active_batches_line(state),
      permission_line(state),
      recent_line(state),
      error_line(state)
    ]
    |> Enum.reject(&(&1 == ""))
  end

  defp clear_current_turn(%{current_turn: turn_id} = state, turn_id, status) do
    %{state | current_turn: nil, status: status}
  end

  defp clear_current_turn(state, _turn_id, status) do
    %{state | status: status}
  end

  defp settle_status(%{current_turn: nil, status: :running} = state) do
    if map_size(state.active_tools) == 0 and map_size(state.active_batches) == 0 do
      %{state | status: :finished}
    else
      state
    end
  end

  defp settle_status(state), do: state

  defp session_segment(%{session_id: nil}), do: ""
  defp session_segment(%{session_id: session_id}), do: [" | session ", session_id]

  defp turn_segment(%{current_turn: nil}), do: ""
  defp turn_segment(%{current_turn: turn_id}), do: [" | turn ", turn_id]

  defp permission_segment(%{permission: %{status: :pending}}), do: " | permission pending"
  defp permission_segment(_state), do: ""

  defp active_tools_line(%{active_tools: tools}) when map_size(tools) == 0, do: ""

  defp active_tools_line(%{active_tools: tools}) do
    tools =
      tools
      |> Enum.sort()
      |> Enum.map_join("; ", &format_tool/1)

    "tools: " <> tools
  end

  defp active_batches_line(%{active_batches: batches}) when map_size(batches) == 0, do: ""

  defp active_batches_line(%{active_batches: batches}) do
    batches =
      batches
      |> Enum.sort()
      |> Enum.map_join("; ", &format_batch/1)

    "batches: " <> batches
  end

  defp permission_line(%{permission: nil}), do: ""

  defp permission_line(%{permission: %{status: :pending} = permission}) do
    "permission: #{permission.request_id} pending #{inspect(permission.action)}"
  end

  defp permission_line(%{permission: %{status: :resolved} = permission}) do
    "permission: #{permission.request_id} resolved #{inspect(permission.decision)}"
  end

  defp recent_line(%{last_tool: nil, last_batch: nil}), do: ""

  defp recent_line(%{last_tool: {_call_id, name, status, summary}}) do
    "last tool: #{name} #{inspect(status)} #{format_summary(summary)}"
  end

  defp recent_line(%{last_batch: {batch_id, status}}) do
    "last batch: #{batch_id} #{inspect(status)}"
  end

  defp error_line(%{last_error: nil}), do: ""

  defp error_line(%{last_error: {scope, reason}}) do
    "error: #{inspect(scope)} #{inspect(reason)}"
  end

  defp format_summary(summary) when is_binary(summary), do: summary
  defp format_summary(summary), do: inspect(summary)

  defp format_batch({batch_id, %{count: count}}) do
    "#{batch_id} (#{count} calls)"
  end

  defp format_tool({call_id, %{name: name, output_bytes: 0}}) do
    "#{name}(#{call_id})"
  end

  defp format_tool({call_id, %{name: name, output_bytes: bytes}}) do
    "#{name}(#{call_id}, #{bytes} B)"
  end
end
