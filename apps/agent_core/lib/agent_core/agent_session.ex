defmodule AgentCore.AgentSession do
  @moduledoc """
  Coordinates one conversational agent session.

  The current skeleton keeps model calls synchronous because the mock client is
  local and deterministic. Real provider implementations should move streaming
  work out of the GenServer through `AgentCore.ToolTaskSupervisor` or a
  provider-specific supervised process.
  """

  use GenServer

  alias AgentCore.ModelClient.Mock

  @type role :: :user | :assistant | :system | :tool
  @type message :: %{role: role(), content: String.t()}
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
            tools: []

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
    GenServer.call(pid, {:send_message, text})
  end

  @doc """
  Returns the session transcript in chronological order.
  """
  @spec messages(pid()) :: {:ok, [message()]}
  def messages(pid) when is_pid(pid) do
    GenServer.call(pid, :messages)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_id: Keyword.get_lazy(opts, :session_id, &new_session_id/0),
      model_client: Keyword.get(opts, :model_client, Mock),
      model_opts: Keyword.get(opts, :model_opts, []),
      tools: Keyword.get(opts, :tools, [])
    }

    publish(AgentCore.Event.session_started(%{session_id: state.session_id}))

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, text}, _from, state) do
    context = new_turn_context(text)
    messages = [context.user_message | state.messages]

    publish_turn_started(state.session_id, context)

    result = stream_chat(state, messages, context)
    handle_stream_result(result, state, messages, context)
  end

  def handle_call(:messages, _from, state) do
    {:reply, {:ok, Enum.reverse(state.messages)}, state}
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
    publish(AgentCore.Event.agent_started(session_id))
    publish(AgentCore.Event.turn_started(context.turn_id))
    publish(AgentCore.Event.message_started(context.user_message_id, :user))
    publish_message_finished(context.user_message_id, context.user_message)
    publish(AgentCore.Event.message_started(context.assistant_message_id, :assistant))
  end

  defp stream_chat(state, messages, context) do
    state.model_client.stream_chat(
      Enum.reverse(messages),
      state.tools,
      state.model_opts,
      message_delta_sink(context.assistant_message_id)
    )
  end

  defp message_delta_sink(message_id) do
    fn delta -> publish(AgentCore.Event.message_delta(message_id, delta)) end
  end

  defp handle_stream_result({:ok, content}, state, messages, context) do
    assistant_message = %{role: :assistant, content: content}

    publish_message_finished(context.assistant_message_id, assistant_message)
    publish_turn_finished(context.turn_id, :ok)
    publish(AgentCore.Event.agent_finished(state.session_id))

    reply = %{message_id: context.assistant_message_id, content: content}
    next_state = %{state | messages: [assistant_message | messages]}

    {:reply, {:ok, reply}, next_state}
  end

  defp handle_stream_result({:error, reason}, state, messages, context) do
    publish(AgentCore.Event.error(:model, reason))
    publish_turn_finished(context.turn_id, {:error, reason})
    publish(AgentCore.Event.agent_finished(state.session_id))

    {:reply, {:error, reason}, %{state | messages: messages}}
  end

  defp publish_message_finished(message_id, message) do
    publish(AgentCore.Event.message_finished(Map.put(message, :id, message_id)))
  end

  defp publish_turn_finished(turn_id, :ok) do
    publish(AgentCore.Event.turn_finished(turn_id, %{status: :ok}))
  end

  defp publish_turn_finished(turn_id, {:error, reason}) do
    publish(AgentCore.Event.turn_finished(turn_id, %{status: :error, reason: reason}))
  end

  defp publish(event) do
    AgentCore.EventBus.publish(event)
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
