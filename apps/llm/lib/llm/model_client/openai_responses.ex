defmodule LLM.ModelClient.OpenAIResponses do
  @moduledoc """
  Public OpenAI Responses API model client.

  The client keeps transcript state local. Each call sends the full local input
  list to the provider and returns either final assistant text or normalized tool
  calls for `Core.AgentSession` to execute.
  """

  @behaviour Core.ModelClient

  alias LLM.ModelClient.OpenAIResponseStream

  @openai_base_url "https://api.openai.com/v1"
  @timeout_ms 120_000

  @impl true
  def stream_chat(messages, tools, opts, event_sink) when is_function(event_sink, 1) do
    with {:ok, request} <- build_request(messages, tools, opts) do
      opts
      |> Keyword.get(:transport, &stream_request/2)
      |> then(fn transport -> transport.(request, event_sink) end)
    end
  end

  @impl true
  def complete_chat(messages, tools, opts) do
    stream_chat(messages, tools, opts, fn _delta -> :ok end)
  end

  @doc false
  @spec build_request([Core.AgentSession.message()], [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_request(messages, tools, opts) do
    with {:ok, model} <- required_model(opts),
         {:ok, api_key} <- resolve_api_key(opts) do
      {:ok,
       %{
         url: endpoint(Keyword.get(opts, :base_url)),
         headers: headers(api_key, opts),
         body: body(model, messages, tools, opts),
         req_opts: Keyword.get(opts, :req_opts, []),
         timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms)
       }}
    end
  end

  @doc false
  @spec from_events([map()], (String.t() -> any())) ::
          {:ok, Core.ModelClient.response()} | {:error, term()}
  def from_events(events, event_sink), do: OpenAIResponseStream.from_events(events, event_sink)

  defp stream_request(request, event_sink) do
    request
    |> Network.HTTP.Stream.post_json(OpenAIResponseStream.initial_state(),
      on_chunk: &OpenAIResponseStream.parse_chunk(&1, &2, event_sink),
      on_success: &finish_stream_body(&1, &2, event_sink)
    )
    |> map_network_error()
  end

  defp finish_stream_body(body, state, event_sink) do
    body
    |> to_string()
    |> OpenAIResponseStream.parse_chunk(state, event_sink)
    |> OpenAIResponseStream.flush(event_sink)
    |> OpenAIResponseStream.finish()
  end

  defp map_network_error({:error, {:network_response_failed, status, body}}) do
    {:error, {:openai_response_failed, status, body}}
  end

  defp map_network_error({:error, {:network_request_failed, reason}}) do
    {:error, {:openai_request_failed, reason}}
  end

  defp map_network_error(result), do: result

  defp required_model(opts) do
    case Keyword.get(opts, :model) || System.get_env("OPENAI_MODEL") do
      model when is_binary(model) and model != "" -> {:ok, model}
      _model -> {:error, :model_required}
    end
  end

  defp resolve_api_key(opts) do
    case Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY") do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _api_key -> {:error, :api_key_required}
    end
  end

  defp endpoint(base_url) do
    base = String.trim_trailing(base_url || @openai_base_url, "/")

    cond do
      String.ends_with?(base, "/responses") -> base
      String.ends_with?(base, "/v1") -> base <> "/responses"
      true -> base <> "/v1/responses"
    end
  end

  defp headers(api_key, opts) do
    [
      {"authorization", "Bearer " <> api_key},
      {"accept", "text/event-stream"},
      {"content-type", "application/json"}
    ]
    |> merge_headers(Keyword.get(opts, :headers, []))
  end

  defp body(model, messages, tools, opts) do
    %{
      model: model,
      stream: true,
      store: false,
      input: Enum.flat_map(Enum.with_index(messages), &message_to_input/1)
    }
    |> maybe_put(:instructions, Keyword.get(opts, :instructions))
    |> maybe_put(:tools, tool_schemas(tools))
    |> maybe_put(:reasoning, reasoning(opts))
  end

  defp message_to_input({%{role: :user, content: content}, _index}) do
    [%{role: "user", content: [%{type: "input_text", text: content}]}]
  end

  defp message_to_input({%{role: :system, content: content}, _index}) do
    [%{role: "system", content: [%{type: "input_text", text: content}]}]
  end

  defp message_to_input({%{role: :assistant, tool_calls: tool_calls} = message, index}) do
    text_items = assistant_text_items(message, index)
    tool_items = Enum.map(tool_calls, &tool_call_to_input/1)

    text_items ++ tool_items
  end

  defp message_to_input({%{role: :assistant} = message, index}) do
    assistant_text_items(message, index)
  end

  defp message_to_input({%{role: :tool} = message, _index}) do
    [
      %{
        type: "function_call_output",
        call_id: message.tool_call_id,
        output: message.content
      }
    ]
  end

  defp message_to_input({_message, _index}), do: []

  defp assistant_text_items(%{content: ""}, _index), do: []

  defp assistant_text_items(%{content: content}, index) when is_binary(content) do
    [
      %{
        type: "message",
        id: "msg_#{index}",
        role: "assistant",
        status: "completed",
        content: [%{type: "output_text", text: content, annotations: []}]
      }
    ]
  end

  defp tool_call_to_input(tool_call) do
    %{
      type: "function_call",
      id: Map.get(tool_call, :provider_id, "fc_" <> safe_id(tool_call.id)),
      call_id: tool_call.id,
      name: tool_call.name,
      arguments: JSON.encode!(tool_call.args)
    }
  end

  defp tool_schemas([]), do: nil

  defp tool_schemas(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        name: tool.name,
        description: tool.description,
        parameters: tool.schema,
        strict: false
      }
    end)
  end

  defp reasoning(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      effort when is_binary(effort) and effort != "" -> %{effort: effort}
      _effort -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp merge_headers(headers, extra_headers) when is_map(extra_headers) do
    merge_headers(headers, Map.to_list(extra_headers))
  end

  defp merge_headers(headers, extra_headers) when is_list(extra_headers) do
    Enum.reduce(extra_headers, headers, fn {key, value}, acc ->
      [{to_string(key), value} | reject_header(acc, to_string(key))]
    end)
  end

  defp reject_header(headers, key) do
    Enum.reject(headers, fn {existing, _value} ->
      String.downcase(existing) == String.downcase(key)
    end)
  end

  defp safe_id(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.slice(0, 60)
  end
end
