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

    AgentCore.EventBus.publish({:session_started, %{session_id: state.session_id}})

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, text}, _from, state) do
    message_id = new_message_id()
    user_message = %{role: :user, content: text}
    messages = [user_message | state.messages]

    AgentCore.EventBus.publish({:user_message, text})
    AgentCore.EventBus.publish({:assistant_message_started, message_id})

    event_sink = fn delta ->
      AgentCore.EventBus.publish({:assistant_delta, message_id, delta})
    end

    case state.model_client.stream_chat(
           Enum.reverse(messages),
           state.tools,
           state.model_opts,
           event_sink
         ) do
      {:ok, content} ->
        AgentCore.EventBus.publish({:assistant_message_finished, message_id})

        reply = %{message_id: message_id, content: content}
        next_state = %{state | messages: [%{role: :assistant, content: content} | messages]}

        {:reply, {:ok, reply}, next_state}

      {:error, reason} ->
        AgentCore.EventBus.publish({:error, :model, reason})
        {:reply, {:error, reason}, %{state | messages: messages}}
    end
  end

  def handle_call(:messages, _from, state) do
    {:reply, {:ok, Enum.reverse(state.messages)}, state}
  end

  defp new_session_id do
    "session-" <> unique_id()
  end

  defp new_message_id do
    "message-" <> unique_id()
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string(36)
  end
end
