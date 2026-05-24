defmodule AgentTui.LiveStatus do
  @moduledoc """
  Maintains a compact live status block for terminal sessions.

  The process subscribes to `AgentCore.EventBus`, reduces core events into a
  small status snapshot, and publishes that snapshot through `Owl.LiveScreen`.
  Transcript rendering stays in `AgentTui.TextRenderer`; this module only owns
  ephemeral status such as the current turn, active tools, active batches, and
  pending permission requests.
  """

  use GenServer

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

  @type t :: %__MODULE__{
          active_batches: %{String.t() => batch_state()},
          active_tools: %{String.t() => tool_state()},
          block_id: term(),
          current_turn: String.t() | nil,
          last_batch: {String.t(), AgentCore.Event.status()} | nil,
          last_error: {atom(), term()} | nil,
          last_tool: {String.t(), String.t(), AgentCore.Event.status(), term()} | nil,
          live_enabled: boolean(),
          permission: permission_state() | nil,
          screen: GenServer.server() | nil,
          session_id: String.t() | nil,
          status: :idle | :running | :finished | :error
        }

  defstruct active_batches: %{},
            active_tools: %{},
            block_id: :agent_tui_status,
            current_turn: nil,
            last_batch: nil,
            last_error: nil,
            last_tool: nil,
            live_enabled: true,
            permission: nil,
            screen: Owl.LiveScreen,
            session_id: nil,
            status: :idle

  @doc """
  Starts a live status process.

  Options:

    * `:screen` - `Owl.LiveScreen` server to update. Defaults to `Owl.LiveScreen`.
    * `:block_id` - LiveScreen block id. Defaults to `:agent_tui_status`.
    * `:live_enabled` - set to `false` for pure state tests.
    * `:subscribe` - set to `false` to skip `AgentCore.EventBus` subscription.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Builds a status snapshot without starting a process.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      block_id: Keyword.get(opts, :block_id, :agent_tui_status),
      live_enabled: Keyword.get(opts, :live_enabled, true),
      screen: Keyword.get(opts, :screen, Owl.LiveScreen)
    }
  end

  @doc """
  Applies one core event to a status snapshot.
  """
  @spec reduce_event(t(), AgentCore.Event.t()) :: t()
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
  Renders a status snapshot as plain iodata.
  """
  @spec render(t()) :: iodata()
  def render(%__MODULE__{} = state) do
    state
    |> status_lines()
    |> Enum.intersperse("\n")
  end

  @impl true
  def init(opts) do
    state = new(opts)

    if Keyword.get(opts, :subscribe, true) do
      :ok = AgentCore.EventBus.subscribe()
    end

    add_block(state)
    update_block(state)

    {:ok, state}
  end

  @impl true
  def handle_info({:agent_core_event, event}, state) do
    next_state = reduce_event(state, event)
    update_block(next_state)

    {:noreply, next_state}
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

  defp add_block(%{live_enabled: false}), do: :ok
  defp add_block(%{screen: nil}), do: :ok

  defp add_block(state) do
    if screen_available?(state.screen) do
      Owl.LiveScreen.add_block(state.screen, state.block_id, state: state, render: &render/1)
    end
  end

  defp update_block(%{live_enabled: false}), do: :ok
  defp update_block(%{screen: nil}), do: :ok

  defp update_block(state) do
    if screen_available?(state.screen) do
      Owl.LiveScreen.update(state.screen, state.block_id, state)
    end
  end

  defp screen_available?(screen) do
    case GenServer.whereis(screen) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _other -> false
    end
  end

  defp status_lines(state) do
    [
      status_line(state),
      batches_line(state),
      tools_line(state),
      permission_line(state),
      recent_line(state),
      error_line(state)
    ]
    |> Enum.reject(&(&1 == []))
  end

  defp status_line(%{current_turn: turn_id, status: :running}) when is_binary(turn_id) do
    ["agent: running turn ", turn_id]
  end

  defp status_line(%{session_id: session_id, status: status}) when is_binary(session_id) do
    ["agent: ", Atom.to_string(status), " session ", session_id]
  end

  defp status_line(%{status: status}) do
    ["agent: ", Atom.to_string(status)]
  end

  defp batches_line(%{active_batches: batches}) when map_size(batches) == 0, do: []

  defp batches_line(%{active_batches: batches}) do
    ["batches: ", batches |> Enum.sort() |> Enum.map_intersperse("; ", &format_batch/1)]
  end

  defp tools_line(%{active_tools: tools}) when map_size(tools) == 0, do: []

  defp tools_line(%{active_tools: tools}) do
    ["tools: ", tools |> Enum.sort() |> Enum.map_intersperse("; ", &format_tool/1)]
  end

  defp permission_line(%{permission: nil}), do: []

  defp permission_line(%{permission: %{status: :pending} = permission}) do
    ["permission: ", permission.request_id, " pending ", inspect(permission.action)]
  end

  defp permission_line(%{permission: %{status: :resolved} = permission}) do
    ["permission: ", permission.request_id, " resolved ", inspect(permission.decision)]
  end

  defp recent_line(%{last_tool: nil, last_batch: nil}), do: []

  defp recent_line(%{last_tool: {_call_id, name, status, summary}}) do
    ["last tool: ", name, " ", inspect(status), " ", to_string(summary)]
  end

  defp recent_line(%{last_batch: {batch_id, status}}) do
    ["last batch: ", batch_id, " ", inspect(status)]
  end

  defp error_line(%{last_error: nil}), do: []

  defp error_line(%{last_error: {scope, reason}}) do
    ["error: ", inspect(scope), " ", inspect(reason)]
  end

  defp format_batch({batch_id, %{count: count}}) do
    [batch_id, " (", Integer.to_string(count), " calls)"]
  end

  defp format_tool({call_id, %{name: name, output_bytes: 0}}) do
    [name, "(", call_id, ")"]
  end

  defp format_tool({call_id, %{name: name, output_bytes: bytes}}) do
    [name, "(", call_id, ", ", Integer.to_string(bytes), " B)"]
  end
end
