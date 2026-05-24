defmodule AgentCore.ModelClient.Mock do
  @moduledoc """
  Deterministic model client for tests and early UI work.
  """

  @behaviour AgentCore.ModelClient

  @impl true
  def stream_chat(messages, _tools, _opts, event_sink) when is_function(event_sink, 1) do
    response = response_for(messages)
    event_sink.(response)
    {:ok, response}
  end

  @impl true
  def complete_chat(messages, _tools, _opts) do
    {:ok, response_for(messages)}
  end

  defp response_for(messages) do
    case last_user_message(messages) do
      nil -> "Mock response."
      text -> "Mock response: " <> text
    end
  end

  defp last_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :user, content: content} -> content
      _message -> nil
    end)
  end
end
