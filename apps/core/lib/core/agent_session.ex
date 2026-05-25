defmodule Core.AgentSession do
  @moduledoc """
  Coordinates one conversational agent session.

  The current skeleton keeps model calls synchronous because the mock client is
  local and deterministic. Real provider implementations should move streaming
  work out of the GenServer through `Core.ToolTaskSupervisor` or a
  provider-specific supervised process.
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

  defstruct session_id: nil,
            messages: [],
            model_client: Mock,
            model_opts: [],
            permission_mode: :read_only,
            tools: [],
            workspace_root: nil,
            file_lock_manager: Core.FileLockManager,
            max_tool_iterations: :infinity

  @doc """
  Starts an unsupervised session process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends user text to the session and streams assistant events.
  """
  @spec send_message(pid(), String.t()) ::
          {:ok, %{message_id: String.t(), content: String.t()}} | {:error, term()}
  def send_message(pid, text) when is_pid(pid) and is_binary(text) do
    GenServer.call(pid, {:send_message, text}, :infinity)
  end

  @doc """
  Returns the session transcript in chronological order.
  """
  @spec messages(pid()) :: {:ok, [message()]}
  def messages(pid) when is_pid(pid) do
    GenServer.call(pid, :messages)
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
      tools: Keyword.get_lazy(opts, :tools, &Core.ToolRegistry.default_tools/0),
      workspace_root: Keyword.get_lazy(opts, :workspace_root, &File.cwd!/0),
      file_lock_manager: Keyword.get(opts, :file_lock_manager, Core.FileLockManager),
      max_tool_iterations: max_tool_iterations(opts)
    }

    publish(Core.Event.session_started(%{session_id: state.session_id}))

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, text}, _from, state) do
    context = new_turn_context(text)
    messages = [context.user_message | state.messages]

    publish_turn_started(state.session_id, context)

    messages
    |> Enum.reverse()
    |> run_model_loop(state, context, 0, context.assistant_message_id)
    |> handle_loop_result(state, context)
  end

  def handle_call(:messages, _from, state) do
    {:reply, {:ok, Enum.reverse(state.messages)}, state}
  end

  def handle_call({:configure_model, opts}, _from, state) do
    {:reply, :ok, configure_state(state, opts)}
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

  defp run_model_loop(messages, state, context, tool_iterations, assistant_message_id) do
    publish(Core.Event.message_started(assistant_message_id, :assistant))

    state
    |> stream_chat(messages, assistant_message_id)
    |> normalize_model_response()
    |> continue_model_loop(messages, state, context, tool_iterations, assistant_message_id)
  end

  defp stream_chat(state, messages, assistant_message_id) do
    state.model_client.stream_chat(
      messages,
      Core.ToolRegistry.schemas(state.tools),
      Keyword.put_new(state.model_opts, :session_id, state.session_id),
      message_delta_sink(assistant_message_id)
    )
  rescue
    exception ->
      {:error, {:model_client_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason ->
      {:error, {:model_client_exit, reason}}

    kind, reason ->
      {:error, {:model_client_throw, kind, reason}}
  end

  defp message_delta_sink(message_id) do
    fn delta -> publish(Core.Event.message_delta(message_id, delta)) end
  end

  defp normalize_model_response({:ok, content}) when is_binary(content) do
    {:ok, %{content: content, tool_calls: []}}
  end

  defp normalize_model_response({:ok, response}) when is_map(response) do
    content = response_content(response)
    tool_calls = Map.get(response, :tool_calls, Map.get(response, "tool_calls", []))

    with {:ok, calls} <- Core.ToolCall.normalize_all(tool_calls) do
      {:ok, %{content: content, tool_calls: calls}}
    end
  end

  defp normalize_model_response({:error, reason}), do: {:error, reason}
  defp normalize_model_response(response), do: {:error, {:invalid_model_response, response}}

  defp response_content(%{content: content}) when is_binary(content), do: content
  defp response_content(%{"content" => content}) when is_binary(content), do: content
  defp response_content(_response), do: ""

  defp continue_model_loop(
         {:ok, %{content: content, tool_calls: []}},
         messages,
         _state,
         _context,
         _tool_iterations,
         assistant_message_id
       ) do
    assistant_message = %{role: :assistant, content: content}

    publish_message_finished(assistant_message_id, assistant_message)

    {:ok, %{message_id: assistant_message_id, content: content}, messages ++ [assistant_message]}
  end

  defp continue_model_loop(
         {:ok, %{content: content, tool_calls: tool_calls}},
         messages,
         state,
         context,
         tool_iterations,
         assistant_message_id
       ) do
    assistant_message = assistant_message(content, tool_calls)
    publish_message_finished(assistant_message_id, assistant_message)

    continue_after_tool_request(
      messages,
      assistant_message,
      tool_calls,
      state,
      context,
      tool_iterations
    )
  end

  defp continue_model_loop(
         {:error, reason},
         messages,
         _state,
         _context,
         _tool_iterations,
         _assistant_message_id
       ) do
    {:error, reason, messages}
  end

  defp assistant_message("", tool_calls),
    do: %{role: :assistant, content: "", tool_calls: tool_calls}

  defp assistant_message(content, tool_calls) do
    %{role: :assistant, content: content, tool_calls: tool_calls}
  end

  defp continue_after_tool_request(
         messages,
         assistant_message,
         tool_calls,
         state,
         context,
         tool_iterations
       ) do
    if tool_limit_reached?(tool_iterations, state.max_tool_iterations) do
      {:error, {:max_tool_iterations_exceeded, state.max_tool_iterations},
       messages ++ [assistant_message]}
    else
      tool_messages = run_tool_calls(tool_calls, state)
      next_messages = messages ++ [assistant_message | tool_messages]

      run_model_loop(next_messages, state, context, tool_iterations + 1, new_message_id())
    end
  end

  defp tool_limit_reached?(_tool_iterations, :infinity), do: false
  defp tool_limit_reached?(tool_iterations, max) when is_integer(max), do: tool_iterations >= max

  defp max_tool_iterations(opts) do
    case Keyword.get(opts, :max_tool_iterations, :infinity) do
      nil -> :infinity
      :infinity -> :infinity
      max when is_integer(max) and max >= 0 -> max
      max -> raise ArgumentError, "invalid :max_tool_iterations #{inspect(max)}"
    end
  end

  defp run_tool_calls(tool_calls, state) do
    Enum.map(tool_calls, &run_tool_call(&1, state))
  end

  defp run_tool_call(tool_call, state) do
    result =
      Core.ToolExecutor.run(tool_call.name, tool_call.args,
        tool_call_id: tool_call.id,
        tools: state.tools,
        workspace_root: state.workspace_root,
        permission_mode: state.permission_mode,
        file_lock_manager: state.file_lock_manager
      )

    tool_message = tool_result_message(tool_call, result)
    tool_message_id = new_message_id()

    publish(Core.Event.message_started(tool_message_id, :tool))
    publish_message_finished(tool_message_id, tool_message)
    tool_message
  end

  defp tool_result_message(tool_call, {:ok, result}) do
    %{
      role: :tool,
      tool_call_id: tool_call.id,
      name: tool_call.name,
      status: :ok,
      content: tool_content(result),
      summary: Map.get(result, :summary, "completed")
    }
  end

  defp tool_result_message(tool_call, {:error, reason}) do
    summary = inspect(reason, charlists: :as_lists)

    %{
      role: :tool,
      tool_call_id: tool_call.id,
      name: tool_call.name,
      status: :error,
      content: summary,
      summary: summary
    }
  end

  defp tool_content(%{output: output}) when is_binary(output), do: output
  defp tool_content(%{summary: summary}) when is_binary(summary), do: summary
  defp tool_content(result), do: inspect(result, charlists: :as_lists)

  defp handle_loop_result({:ok, reply, messages}, state, context) do
    publish_turn_finished(context.turn_id, :ok)
    publish(Core.Event.agent_finished(state.session_id))

    {:reply, {:ok, reply}, %{state | messages: Enum.reverse(messages)}}
  end

  defp handle_loop_result({:error, reason, messages}, state, context) do
    publish(Core.Event.error(:model, reason))
    publish_turn_finished(context.turn_id, {:error, reason})
    publish(Core.Event.agent_finished(state.session_id))

    {:reply, {:error, reason}, %{state | messages: Enum.reverse(messages)}}
  end

  defp publish_message_finished(message_id, message) do
    publish(Core.Event.message_finished(Map.put(message, :id, message_id)))
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

  defp publish_turn_finished(turn_id, {:error, reason}) do
    publish(Core.Event.turn_finished(turn_id, %{status: :error, reason: reason}))
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
