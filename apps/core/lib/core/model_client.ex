defmodule Core.ModelClient do
  @moduledoc """
  Behaviour for model provider adapters.
  """

  @type message :: Core.AgentSession.message()
  @type tool_schema :: map()
  @type tool_call :: Core.ToolCall.t()
  @type stream_sink :: (String.t() -> any())
  @type response ::
          String.t()
          | %{
              required(:content) => String.t(),
              optional(:tool_calls) => [tool_call()]
            }

  @doc """
  Streams a chat response through `event_sink`.

  Returns either final assistant text or a response map containing requested tool
  calls. Session code owns executing tool calls and sending tool result messages
  back through the next model call.
  """
  @callback stream_chat([message()], [tool_schema()], keyword(), stream_sink()) ::
              {:ok, response()} | {:error, term()}

  @doc """
  Completes a chat response without streaming deltas.
  """
  @callback complete_chat([message()], [tool_schema()], keyword()) ::
              {:ok, response()} | {:error, term()}
end
