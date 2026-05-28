defmodule Core.AgentSession do
  @moduledoc """
  Coordinates one conversational agent session.

  The session GenServer owns durable session state: the message transcript and
  the model/tool configuration. Each turn runs in a separate task supervised by
  `Core.TurnTaskSupervisor` (see `Core.TurnRunner`), so the session stays
  responsive during a turn:

    * `send_message/2` stays synchronous for callers: the caller blocks until the
      turn task finishes and the session replies with `GenServer.reply/2`.
    * `messages/1` returns the current transcript even while a turn is running.
    * `abort/1` cancels the active turn and its in-flight tool tasks, keeps the
      session alive, and fails the waiting caller with `{:error, :aborted}`.

  A second prompt submitted during an active turn returns
  `{:error, :turn_in_progress}`.
  """

  use GenServer

  alias Core.ModelClient.Mock

  @type role :: :user | :assistant | :system | :tool
  @type message :: %{
          required(:role) => role(),
          required(:content) => String.t(),
          optional(:tool_calls) => [Core.ToolCall.t()],
          optional(:tool_call_id) => String.t(),
          optional(:name) => String.t(),
          optional(:status) => Core.Event.status(),
          optional(:summary) => String.t()
        }
  @typep turn_context :: %{
           turn_id: String.t(),
           user_message_id: String.t(),
           assistant_message_id: String.t(),
           user_message: message()
         }

  @default_tool_timeout_ms 600_000
  @default_batch_timeout_ms 900_000

  defstruct session_id: nil,
            messages: [],
            model_client: Mock,
            model_opts: [],
            permission_mode: :read_only,
            tools: [],
            workspace_root: nil,
            file_lock_manager: Core.FileLockManager,
            max_tool_iterations: :infinity,
            tool_timeout_ms: @default_tool_timeout_ms,
            batch_timeout_ms: @default_batch_timeout_ms,
            structural_backend: Core.Structural.Backend.Unavailable,
            active_turn: nil

  @doc """
  Starts an unsupervised session process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends user text to the session and streams assistant events.

  Blocks until the turn finishes. Returns `{:error, :turn_in_progress}` if a turn
  is already active, and `{:error, :aborted}` if the turn is cancelled.
  """
  @spec send_message(pid(), String.t()) ::
          {:ok, %{message_id: String.t(), content: String.t()}} | {:error, term()}
  def send_message(pid, text) when is_pid(pid) and is_binary(text) do
    GenServer.call(pid, {:send_message, text}, :infinity)
  end

  @doc """
  Returns the session transcript in chronological order.

  Safe to call while a turn is active; returns the transcript as of turn start.
  """
  @spec messages(pid()) :: {:ok, [message()]}
  def messages(pid) when is_pid(pid) do
    GenServer.call(pid, :messages)
  end

  @doc """
  Cancels the active turn and its in-flight tool tasks.

  Returns `:ok` when a turn was cancelled and `{:error, :no_active_turn}` when
  the session is idle. The waiting `send_message/2` caller receives
  `{:error, :aborted}`.
  """
  @spec abort(pid()) :: :ok | {:error, :no_active_turn}
  def abort(pid) when is_pid(pid) do
    GenServer.call(pid, :abort)
  end

  @doc """
  Reconfigures the model client used for subsequent turns.

  Accepts `:model_client`, `:model_opts`, and optionally `:permission_mode`.
  Existing values are preserved for omitted options.
  """
  @spec configure_model(pid(), keyword()) :: :ok | {:error, term()}
  def configure_model(pid, opts) when is_pid(pid) and is_list(opts) do
    GenServer.call(pid, {:configure_model, opts})
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_id: Keyword.get_lazy(opts, :session_id, &new_session_id/0),
      model_client: Keyword.get(opts, :model_client, Mock),
      model_opts: Keyword.get(opts, :model_opts, []),
      permission_mode: Keyword.get(opts, :permission_mode, :read_only),
      tools: Keyword.get_lazy(opts, :tools, &Core.ToolRegistry.agent_default_tools/0),
      workspace_root: Keyword.get_lazy(opts, :workspace_root, &File.cwd!/0),
      file_lock_manager: Keyword.get(opts, :file_lock_manager, Core.FileLockManager),
      max_tool_iterations: max_tool_iterations(opts),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, @default_tool_timeout_ms),
      batch_timeout_ms: Keyword.get(opts, :batch_timeout_ms, @default_batch_timeout_ms),
      structural_backend:
        Keyword.get(opts, :structural_backend, Core.Structural.Backend.Unavailable)
    }

    publish(Core.Event.session_started(%{session_id: state.session_id}))

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, text}, from, %{active_turn: nil} = state) do
    context = new_turn_context(text)
    state = %{state | messages: [context.user_message | state.messages]}

    publish_turn_started(state.session_id, context)

    task =
      Task.Supervisor.async_nolink(Core.TurnTaskSupervisor, fn ->
        Core.TurnRunner.run(turn_spec(state, context))
      end)

    {:noreply, %{state | active_turn: %{task: task, from: from, turn_id: context.turn_id}}}
  end

  def handle_call({:send_message, _text}, _from, state) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call(:messages, _from, state) do
    {:reply, {:ok, Enum.reverse(state.messages)}, state}
  end

  def handle_call(:abort, _from, %{active_turn: nil} = state) do
    {:reply, {:error, :no_active_turn}, state}
  end

  def handle_call(:abort, _from, %{active_turn: turn} = state) do
    Task.Supervisor.terminate_child(Core.TurnTaskSupervisor, turn.task.pid)
    Process.demonitor(turn.task.ref, [:flush])

    publish(Core.Event.error(:session, :aborted))
    publish_turn_finished(turn.turn_id, :cancelled)
    publish(Core.Event.agent_finished(state.session_id))
    GenServer.reply(turn.from, {:error, :aborted})

    {:reply, :ok, %{state | active_turn: nil}}
  end

  def handle_call({:configure_model, opts}, _from, state) do
    {:reply, :ok, configure_state(state, opts)}
  end

  @impl true
  def handle_info({ref, outcome}, state) when is_reference(ref) do
    case state.active_turn do
      %{task: %{ref: ^ref}} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish_turn(outcome, state)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case state.active_turn do
      %{task: %{ref: ^ref}} ->
        outcome = {:error, {:turn_crashed, reason}, Enum.reverse(state.messages)}
        {:noreply, finish_turn(outcome, state)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec turn_spec(%__MODULE__{}, turn_context()) :: Core.TurnRunner.spec()
  defp turn_spec(state, context) do
    %{
      session_id: state.session_id,
      turn_id: context.turn_id,
      assistant_message_id: context.assistant_message_id,
      messages: Enum.reverse(state.messages),
      model_client: state.model_client,
      model_opts: state.model_opts,
      tools: state.tools,
      workspace_root: state.workspace_root,
      permission_mode: state.permission_mode,
      file_lock_manager: state.file_lock_manager,
      max_tool_iterations: state.max_tool_iterations,
      tool_timeout_ms: state.tool_timeout_ms,
      batch_timeout_ms: state.batch_timeout_ms,
      structural_backend: state.structural_backend
    }
  end

  defp finish_turn({:ok, reply, messages}, state) do
    turn = state.active_turn
    publish_turn_finished(turn.turn_id, :ok)
    publish(Core.Event.agent_finished(state.session_id))
    GenServer.reply(turn.from, {:ok, reply})

    %{state | messages: Enum.reverse(messages), active_turn: nil}
  end

  defp finish_turn({:error, reason, messages}, state) do
    turn = state.active_turn
    publish(Core.Event.error(:model, reason))
    publish_turn_finished(turn.turn_id, {:error, reason})
    publish(Core.Event.agent_finished(state.session_id))
    GenServer.reply(turn.from, {:error, reason})

    %{state | messages: Enum.reverse(messages), active_turn: nil}
  end

  @spec new_turn_context(String.t()) :: turn_context()
  defp new_turn_context(text) do
    %{
      turn_id: new_turn_id(),
      user_message_id: new_message_id(),
      assistant_message_id: new_message_id(),
      user_message: %{role: :user, content: text}
    }
  end

  defp publish_turn_started(session_id, context) do
    publish(Core.Event.agent_started(session_id))
    publish(Core.Event.turn_started(context.turn_id))
    publish(Core.Event.message_started(context.user_message_id, :user))
    publish_message_finished(context.user_message_id, context.user_message)
  end

  defp max_tool_iterations(opts) do
    case Keyword.get(opts, :max_tool_iterations, :infinity) do
      nil -> :infinity
      :infinity -> :infinity
      max when is_integer(max) and max >= 0 -> max
      max -> raise ArgumentError, "invalid :max_tool_iterations #{inspect(max)}"
    end
  end

  defp configure_state(state, opts) do
    state
    |> maybe_put(:model_client, Keyword.get(opts, :model_client, :__keep__))
    |> maybe_put(:model_opts, Keyword.get(opts, :model_opts, :__keep__))
    |> maybe_put(:permission_mode, Keyword.get(opts, :permission_mode, :__keep__))
  end

  defp maybe_put(state, _key, :__keep__), do: state
  defp maybe_put(state, key, value), do: Map.put(state, key, value)

  defp publish_turn_finished(turn_id, :ok) do
    publish(Core.Event.turn_finished(turn_id, %{status: :ok}))
  end

  defp publish_turn_finished(turn_id, :cancelled) do
    publish(Core.Event.turn_finished(turn_id, %{status: :cancelled}))
  end

  defp publish_turn_finished(turn_id, {:error, reason}) do
    publish(Core.Event.turn_finished(turn_id, %{status: :error, reason: reason}))
  end

  defp publish_message_finished(message_id, message) do
    publish(Core.Event.message_finished(Map.put(message, :id, message_id)))
  end

  defp publish(event) do
    Core.EventBus.publish(event)
  end

  defp new_session_id do
    "session-" <> unique_id()
  end

  defp new_message_id do
    "message-" <> unique_id()
  end

  defp new_turn_id do
    "turn-" <> unique_id()
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string(36)
  end
end
