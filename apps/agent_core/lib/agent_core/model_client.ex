defmodule AgentCore.ModelClient do
  @moduledoc """
  Behaviour for model provider adapters.
  """

  @type message :: AgentCore.AgentSession.message()
  @type tool_schema :: map()
  @type stream_sink :: (String.t() -> any())

  @doc """
  Streams a chat response through `event_sink` and returns the final content.
  """
  @callback stream_chat([message()], [tool_schema()], keyword(), stream_sink()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Completes a chat response without streaming deltas.
  """
  @callback complete_chat([message()], [tool_schema()], keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
