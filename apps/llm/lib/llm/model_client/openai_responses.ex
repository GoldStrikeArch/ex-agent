defmodule LLM.ModelClient.OpenAIResponses do
  @moduledoc """
  OpenAI Responses API model client.

  The client keeps transcript state local. Each call sends the full local input
  list to the provider and returns either final assistant text or normalized tool
  calls for `Core.AgentSession` to execute.
  """

  @behaviour Core.ModelClient

  alias LLM.Auth.Credential

  @openai_base_url "https://api.openai.com/v1"
  @codex_base_url "https://chatgpt.com/backend-api"
  @timeout_ms 120_000
  @codex_originator "pi"
  @codex_user_agent "pi (elixir-agent)"

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
         {:ok, auth} <- resolve_auth(opts) do
      provider = Keyword.get(opts, :provider, auth.provider)

      {:ok,
       %{
         url: endpoint(provider, Keyword.get(opts, :base_url)),
         headers: headers(provider, auth, opts),
         body: body(model, messages, tools, opts),
         req_opts: Keyword.get(opts, :req_opts, []),
         timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms)
       }}
    end
  end

  @doc false
  @spec from_events([map()], (String.t() -> any())) ::
          {:ok, Core.ModelClient.response()} | {:error, term()}
  def from_events(events, event_sink) when is_list(events) and is_function(event_sink, 1) do
    events
    |> Enum.reduce_while({:ok, initial_stream_state()}, &reduce_event(event_sink, &1, &2))
    |> finish_stream_state()
  end

  defp stream_request(request, event_sink) do
    request
    |> Network.HTTP.Stream.post_json(initial_stream_state(),
      on_chunk: &parse_chunk(&1, &2, event_sink),
      on_success: &finish_stream_body(&1, &2, event_sink)
    )
    |> map_network_error()
  end

  defp finish_stream_body(body, state, event_sink) do
    body
    |> to_string()
    |> parse_chunk(state, event_sink)
    |> flush_buffer(event_sink)
    |> finish_stream_state()
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

  defp resolve_auth(opts) do
    provider = Keyword.get(opts, :provider, :openai)
    auth_provider = Keyword.get(opts, :auth_provider)

    cond do
      auth_provider == :openai_codex or provider == :openai_codex ->
        resolve_codex_auth(opts)

      api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY") ->
        {:ok, %{provider: :openai, token: api_key, account_id: nil}}

      true ->
        {:error, :api_key_required}
    end
  end

  defp resolve_codex_auth(opts) do
    with {:ok, credential} <- codex_credential(opts) do
      {:ok,
       %{
         provider: :openai_codex,
         token: credential.access,
         account_id: credential.account_id
       }}
    end
  end

  defp codex_credential(opts) do
    cond do
      match?(%Credential{}, Keyword.get(opts, :credential)) ->
        {:ok, Keyword.fetch!(opts, :credential)}

      resolver = Keyword.get(opts, :credential_resolver) ->
        resolve_credential_with(resolver, opts)

      true ->
        {:error, :credential_resolver_required}
    end
  end

  defp resolve_credential_with(resolver, opts) when is_function(resolver, 2) do
    resolver.(:openai_codex, opts)
  end

  defp resolve_credential_with(resolver, _opts) when is_function(resolver, 1) do
    resolver.(:openai_codex)
  end

  defp resolve_credential_with(resolver, _opts),
    do: {:error, {:invalid_credential_resolver, resolver}}

  defp endpoint(:openai_codex, base_url), do: codex_endpoint(base_url || @codex_base_url)
  defp endpoint(_provider, base_url), do: openai_endpoint(base_url || @openai_base_url)

  defp openai_endpoint(base_url) do
    base = String.trim_trailing(base_url, "/")

    cond do
      String.ends_with?(base, "/responses") -> base
      String.ends_with?(base, "/v1") -> base <> "/responses"
      true -> base <> "/v1/responses"
    end
  end

  defp codex_endpoint(base_url) do
    base = String.trim_trailing(base_url, "/")

    cond do
      String.ends_with?(base, "/codex/responses") -> base
      String.ends_with?(base, "/codex") -> base <> "/responses"
      true -> base <> "/codex/responses"
    end
  end

  defp headers(:openai_codex, auth, opts) do
    [
      {"authorization", "Bearer " <> auth.token},
      {"chatgpt-account-id", auth.account_id},
      {"originator", @codex_originator},
      {"user-agent", @codex_user_agent},
      {"openai-beta", "responses=experimental"},
      {"accept", "text/event-stream"},
      {"content-type", "application/json"}
    ]
    |> maybe_put_header("session_id", Keyword.get(opts, :session_id))
    |> maybe_put_header("x-client-request-id", Keyword.get(opts, :session_id))
    |> merge_headers(Keyword.get(opts, :headers, []))
  end

  defp headers(_provider, auth, opts) do
    [
      {"authorization", "Bearer " <> auth.token},
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
    |> maybe_put(:tools, tool_schemas(tools, opts))
    |> maybe_put(:reasoning, reasoning(opts))
    |> maybe_put_codex_options(opts)
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

  defp tool_schemas([], _opts), do: nil

  defp tool_schemas(tools, opts) do
    strict = tool_strict(opts)

    Enum.map(tools, fn tool ->
      %{
        type: "function",
        name: tool.name,
        description: tool.description,
        parameters: tool.schema,
        strict: strict
      }
    end)
  end

  defp tool_strict(opts) do
    if codex_opts?(opts), do: nil, else: false
  end

  defp reasoning(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      effort when is_binary(effort) and effort != "" -> %{effort: effort}
      _effort -> nil
    end
  end

  defp maybe_put_codex_options(body, opts) do
    if codex_opts?(opts) do
      body
      |> Map.put(:text, %{verbosity: Keyword.get(opts, :text_verbosity, "low")})
      |> Map.put(:include, ["reasoning.encrypted_content"])
      |> Map.put(:tool_choice, "auto")
      |> Map.put(:parallel_tool_calls, true)
      |> maybe_put(:prompt_cache_key, prompt_cache_key(opts))
    else
      body
    end
  end

  defp codex_opts?(opts) do
    Keyword.get(opts, :provider) == :openai_codex or
      Keyword.get(opts, :auth_provider) == :openai_codex
  end

  defp prompt_cache_key(opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        String.slice(session_id, 0, 64)

      _session_id ->
        nil
    end
  end

  defp initial_stream_state do
    %{sse: Network.SSE.new(), content: "", tool_calls: %{}}
  end

  defp parse_chunk("", state, _event_sink), do: {:ok, state}

  defp parse_chunk(chunk, state, event_sink) do
    with {:ok, payloads, sse} <- Network.SSE.parse_chunk(state.sse, chunk) do
      reduce_sse_payloads(payloads, %{state | sse: sse}, event_sink)
    end
  end

  defp flush_buffer({:ok, state}, event_sink) do
    with {:ok, payloads, sse} <- Network.SSE.flush(state.sse) do
      reduce_sse_payloads(payloads, %{state | sse: sse}, event_sink)
    end
  end

  defp flush_buffer({:error, reason}, _event_sink), do: {:error, reason}

  defp reduce_sse_payloads(payloads, state, event_sink) do
    Enum.reduce_while(payloads, {:ok, state}, fn payload, {:ok, next_state} ->
      case parse_sse_payload(payload) do
        {:ok, nil} -> {:cont, {:ok, next_state}}
        {:ok, parsed} -> reduce_event(event_sink, parsed, {:ok, next_state})
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_sse_payload(payload) when payload in ["", "[DONE]"], do: {:ok, nil}
  defp parse_sse_payload(payload), do: JSON.decode(payload)

  defp reduce_event(event_sink, event, {:ok, state}) do
    case event_type(event) do
      "response.output_text.delta" ->
        delta = Map.get(event, "delta", "")
        event_sink.(delta)
        {:cont, {:ok, %{state | content: state.content <> delta}}}

      "response.output_item.added" ->
        {:cont, {:ok, add_output_item(state, event)}}

      "response.function_call_arguments.delta" ->
        {:cont, {:ok, append_tool_arguments(state, event)}}

      "response.function_call_arguments.done" ->
        {:cont, {:ok, finish_tool_arguments(state, event)}}

      "response.output_item.done" ->
        {:cont, {:ok, finish_output_item(state, event)}}

      "response.failed" ->
        {:halt, {:error, {:openai_response_failed, Map.get(event, "response", event)}}}

      "error" ->
        {:halt, {:error, {:openai_stream_error, event}}}

      _event ->
        {:cont, {:ok, state}}
    end
  end

  defp add_output_item(state, event) do
    item = Map.get(event, "item", %{})

    if Map.get(item, "type") == "function_call" do
      index = output_index(event)

      tool_call = %{
        id: Map.get(item, "call_id"),
        provider_id: Map.get(item, "id"),
        name: Map.get(item, "name"),
        arguments: Map.get(item, "arguments", "")
      }

      put_in(state, [:tool_calls, index], tool_call)
    else
      state
    end
  end

  defp append_tool_arguments(state, event) do
    index = output_index(event)
    delta = Map.get(event, "delta", "")

    update_in(state, [:tool_calls, index], fn
      nil -> %{id: nil, name: nil, arguments: delta}
      tool_call -> Map.update(tool_call, :arguments, delta, &(&1 <> delta))
    end)
  end

  defp finish_tool_arguments(state, event) do
    index = output_index(event)
    arguments = Map.get(event, "arguments") || get_in(event, ["item", "arguments"])

    if is_binary(arguments) do
      update_in(state, [:tool_calls, index], fn
        nil -> %{id: nil, name: nil, arguments: arguments}
        tool_call -> Map.put(tool_call, :arguments, arguments)
      end)
    else
      state
    end
  end

  defp finish_output_item(state, %{"item" => %{"type" => "function_call"} = item} = event) do
    update_in(state, [:tool_calls, output_index(event)], &finish_tool_call(&1, item))
  end

  defp finish_output_item(state, _event), do: state

  defp finish_tool_call(tool_call, item) do
    base = tool_call || %{}

    base
    |> Map.put(:id, Map.get(item, "call_id"))
    |> Map.put(:provider_id, Map.get(item, "id"))
    |> Map.put(:name, Map.get(item, "name"))
    |> Map.put(:arguments, Map.get(item, "arguments", Map.get(base, :arguments, "")))
  end

  defp finish_stream_state({:ok, state}) do
    with {:ok, tool_calls} <- normalize_tool_calls(state.tool_calls) do
      case tool_calls do
        [] -> {:ok, state.content}
        calls -> {:ok, %{content: state.content, tool_calls: calls}}
      end
    end
  end

  defp finish_stream_state({:error, reason}), do: {:error, reason}

  defp normalize_tool_calls(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.map(fn {_index, call} -> call end)
    |> Enum.reduce_while({:ok, []}, &normalize_tool_call/2)
    |> reverse_calls()
  end

  defp normalize_tool_call(call, {:ok, calls}) do
    with {:ok, args} <- decode_arguments(call.arguments || ""),
         {:ok, tool_call} <-
           Core.ToolCall.normalize(%{
             id: call.id,
             provider_id: call.provider_id,
             name: call.name,
             args: args
           }) do
      {:cont, {:ok, [tool_call | calls]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reverse_calls({:ok, calls}), do: {:ok, Enum.reverse(calls)}
  defp reverse_calls(error), do: error

  defp decode_arguments(""), do: {:ok, %{}}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:error, {:invalid_tool_arguments, decoded}}
      {:error, reason} -> {:error, {:invalid_tool_arguments, reason}}
    end
  end

  defp output_index(event), do: Map.get(event, "output_index", 0)
  defp event_type(event), do: Map.get(event, "type")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, key, value), do: [{key, value} | headers]

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
