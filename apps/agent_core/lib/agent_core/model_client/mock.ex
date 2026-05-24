defmodule AgentCore.ModelClient.Mock do
  @moduledoc """
  Deterministic model client for tests and early UI work.

  Pass `script: [...]` in model options to return scripted responses for each
  model call in the current turn. Script entries can be strings, response maps,
  `{:tool_call, name, args}`, or `{:tool_calls, calls}`.
  """

  @behaviour AgentCore.ModelClient

  @impl true
  def stream_chat(messages, _tools, opts, event_sink) when is_function(event_sink, 1) do
    with {:ok, response} <- response_for(messages, opts) do
      response
      |> response_content()
      |> emit_response(event_sink)

      {:ok, response}
    end
  end

  @impl true
  def complete_chat(messages, _tools, opts) do
    response_for(messages, opts)
  end

  defp response_for(messages, opts) do
    case Keyword.get(opts, :script) do
      script when is_list(script) -> scripted_response(messages, script)
      _script -> {:ok, default_response_for(messages)}
    end
  end

  defp scripted_response(messages, script) do
    case Enum.at(script, script_index(messages)) do
      nil -> {:ok, default_response_for(messages)}
      item -> normalize_script_item(item)
    end
  end

  defp normalize_script_item(text) when is_binary(text), do: {:ok, text}

  defp normalize_script_item({:tool_call, name, args}) do
    normalize_tool_calls([%{name: name, args: args}])
  end

  defp normalize_script_item({:tool_calls, calls}), do: normalize_tool_calls(calls)

  defp normalize_script_item(%{tool_calls: calls} = response) do
    normalize_tool_calls(calls, Map.get(response, :content, ""))
  end

  defp normalize_script_item(%{"tool_calls" => calls} = response) do
    normalize_tool_calls(calls, Map.get(response, "content", ""))
  end

  defp normalize_script_item(%{content: content}) when is_binary(content), do: {:ok, content}
  defp normalize_script_item(%{"content" => content}) when is_binary(content), do: {:ok, content}

  defp normalize_script_item(%{name: _name} = call), do: normalize_tool_calls([call])
  defp normalize_script_item(%{"name" => _name} = call), do: normalize_tool_calls([call])

  defp normalize_script_item(item), do: {:error, {:invalid_mock_script_item, item}}

  defp normalize_tool_calls(calls, content \\ "")

  defp normalize_tool_calls(calls, content) when is_binary(content) do
    with {:ok, tool_calls} <- AgentCore.ToolCall.normalize_all(calls) do
      {:ok, %{content: content, tool_calls: tool_calls}}
    end
  end

  defp normalize_tool_calls(_calls, content), do: {:error, {:invalid_mock_content, content}}

  defp script_index(messages) do
    messages
    |> messages_after_latest_user()
    |> Enum.count(&match?(%{role: :assistant}, &1))
  end

  defp messages_after_latest_user(messages) do
    Enum.reduce_while(Enum.reverse(messages), [], fn
      %{role: :user}, acc -> {:halt, acc}
      message, acc -> {:cont, [message | acc]}
    end)
  end

  defp default_response_for(messages) do
    case last_tool_message(messages) do
      nil -> default_user_response(messages)
      %{content: content} -> "Mock response after tool: " <> content
    end
  end

  defp default_user_response(messages) do
    case last_user_message(messages) do
      nil -> "Mock response."
      text -> "Mock response: " <> text
    end
  end

  defp last_tool_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn
      %{role: :tool} -> true
      _message -> false
    end)
  end

  defp last_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :user, content: content} -> content
      _message -> nil
    end)
  end

  defp response_content(%{content: content}) when is_binary(content), do: content
  defp response_content(content) when is_binary(content), do: content

  defp emit_response("", _event_sink), do: :ok

  defp emit_response(content, event_sink) do
    event_sink.(content)
  end
end
