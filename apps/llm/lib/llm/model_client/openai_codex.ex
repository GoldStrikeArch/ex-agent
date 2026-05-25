defmodule LLM.ModelClient.OpenAICodex do
  @moduledoc """
  ChatGPT/Codex subscription model client.

  This client targets the ChatGPT backend Codex Responses endpoint, not the
  public OpenAI API. It defaults to a cached WebSocket transport and falls back
  to SSE only when WebSocket setup fails before any stream event is received.
  """

  @behaviour Core.ModelClient

  alias LLM.Auth.Credential
  alias LLM.ModelClient.OpenAIResponseStream

  @codex_base_url "https://chatgpt.com/backend-api"
  @timeout_ms 120_000
  @originator "ex-agent"
  @user_agent "ex (elixir-agent)"
  @sse_beta "responses=experimental"
  @websocket_beta "responses_websockets=2026-02-06"

  @typedoc """
  Transport-ready Codex request.

  `:headers` is kept as an SSE-header alias for injected transports that expect
  the same shape as `Network.HTTP.Stream`.
  """
  @type request :: %{
          required(:url) => String.t(),
          required(:websocket_url) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:sse_headers) => [{String.t(), String.t()}],
          required(:websocket_headers) => [{String.t(), String.t()}],
          required(:body) => map(),
          required(:req_opts) => keyword(),
          required(:timeout_ms) => pos_integer(),
          required(:idle_timeout_ms) => pos_integer(),
          required(:session_id) => String.t() | nil,
          required(:request_id) => String.t()
        }

  @typedoc """
  Cached WebSocket continuation data stored by the network session.
  """
  @type continuation :: %{
          required(:last_request_body) => map(),
          required(:last_response_id) => String.t(),
          required(:response_input) => [map()]
        }

  @typedoc """
  How a request body should be sent over WebSocket.
  """
  @type websocket_body_status :: :full | :delta | :mismatch

  @impl true
  def stream_chat(messages, tools, opts, event_sink) when is_function(event_sink, 1) do
    with {:ok, request} <- build_request(messages, tools, opts) do
      stream_transport(request, opts, event_sink)
    end
  end

  @impl true
  def complete_chat(messages, tools, opts) do
    stream_chat(messages, tools, opts, fn _delta -> :ok end)
  end

  @doc """
  Builds a Codex backend request for both SSE and WebSocket transports.

  The returned request contains the shared JSON body, the SSE endpoint and
  headers, and the WebSocket endpoint and headers. It resolves
  `:openai_codex` credentials from either `:credential` or
  `:credential_resolver`.

  Expected failures are returned as tagged errors, including `:model_required`
  and `:credential_resolver_required`.
  """
  @spec build_request([Core.AgentSession.message()], [map()], keyword()) ::
          {:ok, request()} | {:error, term()}
  def build_request(messages, tools, opts) do
    with {:ok, model} <- required_model(opts),
         {:ok, auth} <- resolve_auth(opts) do
      session_id = session_id(opts)
      request_id = session_id || request_id(opts)
      url = codex_endpoint(Keyword.get(opts, :base_url))
      body = body(model, messages, tools, opts)
      sse_headers = sse_headers(auth, session_id, request_id, opts)
      websocket_headers = websocket_headers(auth, session_id, request_id, opts)

      {:ok,
       %{
         url: url,
         websocket_url: websocket_url(url),
         headers: sse_headers,
         sse_headers: sse_headers,
         websocket_headers: websocket_headers,
         body: body,
         req_opts: Keyword.get(opts, :req_opts, []),
         timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms),
         idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @timeout_ms),
         session_id: session_id,
         request_id: request_id
       }}
    end
  end

  @doc """
  Reduces decoded Responses stream events into a normalized model response.

  This is mainly useful for tests and injected transports that already have
  provider events decoded as maps. Text deltas are forwarded to `event_sink` as
  they are processed.
  """
  @spec from_events([map()], (String.t() -> any())) ::
          {:ok, Core.ModelClient.response()} | {:error, term()}
  def from_events(events, event_sink), do: OpenAIResponseStream.from_events(events, event_sink)

  @doc """
  Prepares a WebSocket request body using cached continuation metadata.

  Returns `{:full, body}` when no continuation is available, `{:delta, body}`
  when the cached response can be reused with `previous_response_id`, or
  `{:mismatch, body}` when the cached continuation does not match the current
  request and must be discarded.
  """
  @spec prepare_websocket_body(map(), continuation() | map() | nil) ::
          {websocket_body_status(), map()}
  def prepare_websocket_body(body, nil), do: {:full, body}

  def prepare_websocket_body(
        body,
        %{last_request_body: previous_body, last_response_id: previous_response_id} = continuation
      )
      when is_map(previous_body) and is_binary(previous_response_id) and
             previous_response_id != "" do
    response_input = Map.get(continuation, :response_input, [])
    prefix = Map.get(previous_body, :input, []) ++ response_input

    if continuation_matches?(body, previous_body, prefix) do
      {:delta, delta_body(body, prefix, previous_response_id)}
    else
      {:mismatch, body}
    end
  end

  def prepare_websocket_body(body, _continuation), do: {:mismatch, body}

  @doc """
  Builds reusable WebSocket continuation metadata from a completed response.

  Metadata is returned only when the response stream produced a provider
  response id. The metadata stores the full request body, the last response id,
  and response output items that are safe to reuse as an input prefix.
  """
  @spec continuation_metadata(map(), OpenAIResponseStream.state()) :: continuation() | nil
  def continuation_metadata(full_body, state) do
    state
    |> OpenAIResponseStream.response_id()
    |> continuation_metadata(full_body, state)
  end

  defp stream_transport(request, opts, event_sink) do
    case Keyword.get(opts, :transport, :auto) do
      :auto -> stream_auto(request, opts, event_sink)
      :sse -> stream_sse(request, opts, event_sink)
      :websocket -> stream_websocket(request, opts, event_sink)
      transport when is_function(transport, 2) -> transport.(sse_request(request), event_sink)
      transport -> {:error, {:invalid_codex_transport, transport}}
    end
  end

  defp stream_auto(request, opts, event_sink) do
    case stream_websocket(request, opts, event_sink) do
      {:error, {:openai_codex_websocket_failed, :before_start, _reason}} ->
        stream_sse(request, opts, event_sink)

      result ->
        result
    end
  end

  defp stream_sse(request, opts, event_sink) do
    transport = Keyword.get(opts, :sse_transport, &stream_sse_request/2)
    request = sse_request(request)

    transport.(request, event_sink)
  end

  defp stream_sse_request(request, event_sink) do
    request
    |> Network.HTTP.Stream.post_json(OpenAIResponseStream.initial_state(),
      on_chunk: &OpenAIResponseStream.parse_chunk(&1, &2, event_sink),
      on_success: &finish_stream_body(&1, &2, event_sink)
    )
    |> map_sse_error()
  end

  defp finish_stream_body(body, state, event_sink) do
    body
    |> to_string()
    |> OpenAIResponseStream.parse_chunk(state, event_sink)
    |> OpenAIResponseStream.flush(event_sink)
    |> OpenAIResponseStream.finish()
  end

  defp stream_websocket(request, opts, event_sink) do
    with {:ok, websocket_request} <- websocket_request(request, opts) do
      opts
      |> Keyword.get(:websocket_transport, &Network.WebSocket.Stream.post_text/3)
      |> then(fn transport ->
        transport.(websocket_request, OpenAIResponseStream.initial_state(),
          on_text: &handle_websocket_text(&1, &2, request.body, event_sink),
          on_success: fn state, _metadata -> OpenAIResponseStream.finish({:ok, state}) end
        )
      end)
      |> map_websocket_error()
    end
  end

  defp websocket_request(request, opts) do
    cache_key = request.session_id
    continuation = cached_metadata(cache_key)
    {continuation_status, body} = prepare_websocket_body(request.body, continuation)

    if continuation_status == :mismatch do
      close_cached_session(cache_key)
    end

    payload =
      body
      |> Map.put(:type, "response.create")
      |> JSON.encode!()

    {:ok,
     %{
       url: request.websocket_url,
       headers: request.websocket_headers,
       text: payload,
       cache_key: cache_key,
       timeout_ms: request.timeout_ms,
       idle_timeout_ms: request.idle_timeout_ms,
       connect_opts: Keyword.get(opts, :connect_opts, []),
       websocket_opts: Keyword.get(opts, :websocket_opts, [])
     }}
  end

  defp cached_metadata(nil), do: nil

  defp cached_metadata(cache_key) do
    if Process.whereis(Network.WebSocket.SessionPool) do
      Network.WebSocket.Stream.metadata(cache_key)
    end
  end

  defp close_cached_session(nil), do: :ok

  defp close_cached_session(cache_key) do
    if Process.whereis(Network.WebSocket.SessionPool) do
      Network.WebSocket.Stream.close(cache_key)
    end

    :ok
  end

  defp handle_websocket_text(text, state, full_body, event_sink) do
    with {:ok, event} <- parse_websocket_event(text),
         {:ok, next_state} <- OpenAIResponseStream.parse_event(event, state, event_sink) do
      if OpenAIResponseStream.completed?(event) do
        {:halt, next_state, continuation_metadata(full_body, next_state)}
      else
        {:cont, next_state}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_websocket_event("[DONE]"), do: {:ok, %{"type" => "response.completed"}}
  defp parse_websocket_event(text), do: JSON.decode(text)

  defp map_sse_error({:error, {:network_response_failed, status, body}}) do
    {:error, {:openai_codex_response_failed, status, body}}
  end

  defp map_sse_error({:error, {:network_request_failed, reason}}) do
    {:error, {:openai_codex_request_failed, reason}}
  end

  defp map_sse_error(result), do: result

  defp map_websocket_error({:error, {:network_websocket_failed, phase, reason}}) do
    {:error, {:openai_codex_websocket_failed, phase, reason}}
  end

  defp map_websocket_error(result), do: result

  defp sse_request(request) do
    %{
      url: request.url,
      headers: request.sse_headers,
      body: request.body,
      req_opts: request.req_opts,
      timeout_ms: request.timeout_ms
    }
  end

  defp required_model(opts) do
    case Keyword.get(opts, :model) || System.get_env("OPENAI_CODEX_MODEL") ||
           System.get_env("OPENAI_MODEL") do
      model when is_binary(model) and model != "" -> {:ok, model}
      _model -> {:error, :model_required}
    end
  end

  defp resolve_auth(opts) do
    with {:ok, credential} <- codex_credential(opts) do
      {:ok,
       %{
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

  defp codex_endpoint(base_url) do
    base = String.trim_trailing(base_url || @codex_base_url, "/")

    cond do
      String.ends_with?(base, "/codex/responses") -> base
      String.ends_with?(base, "/codex") -> base <> "/responses"
      true -> base <> "/codex/responses"
    end
  end

  defp websocket_url(url) do
    url
    |> URI.parse()
    |> Map.update!(:scheme, &websocket_scheme/1)
    |> URI.to_string()
  end

  defp websocket_scheme("http"), do: "ws"
  defp websocket_scheme("https"), do: "wss"
  defp websocket_scheme("ws"), do: "ws"
  defp websocket_scheme("wss"), do: "wss"
  defp websocket_scheme(scheme), do: scheme

  defp sse_headers(auth, session_id, request_id, opts) do
    auth
    |> base_headers(session_id, request_id)
    |> Kernel.++([
      {"openai-beta", @sse_beta},
      {"accept", "text/event-stream"},
      {"content-type", "application/json"}
    ])
    |> merge_headers(Keyword.get(opts, :headers, []))
  end

  defp websocket_headers(auth, session_id, request_id, opts) do
    auth
    |> base_headers(session_id, request_id)
    |> Kernel.++([{"openai-beta", @websocket_beta}])
    |> merge_headers(Keyword.get(opts, :headers, []))
    |> reject_header("accept")
    |> reject_header("content-type")
  end

  defp base_headers(auth, session_id, request_id) do
    [
      {"authorization", "Bearer " <> auth.token},
      {"originator", @originator},
      {"user-agent", @user_agent}
    ]
    |> maybe_put_header("chatgpt-account-id", auth.account_id)
    |> maybe_put_header("session_id", session_id)
    |> maybe_put_header("x-client-request-id", request_id)
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
    |> Map.put(:text, %{verbosity: Keyword.get(opts, :text_verbosity, "low")})
    |> Map.put(:include, ["reasoning.encrypted_content"])
    |> Map.put(:tool_choice, "auto")
    |> Map.put(:parallel_tool_calls, true)
    |> maybe_put(:prompt_cache_key, prompt_cache_key(opts))
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
        strict: nil
      }
    end)
  end

  defp reasoning(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      effort when is_binary(effort) and effort != "" -> %{effort: effort}
      _effort -> nil
    end
  end

  defp prompt_cache_key(opts) do
    case session_id(opts) do
      session_id when is_binary(session_id) and session_id != "" ->
        String.slice(session_id, 0, 64)

      _session_id ->
        nil
    end
  end

  defp session_id(opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and session_id != "" -> session_id
      _session_id -> nil
    end
  end

  defp request_id(opts) do
    case Keyword.get(opts, :request_id) do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      _request_id -> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    end
  end

  defp continuation_metadata(response_id, full_body, state)
       when is_binary(response_id) and response_id != "" do
    %{
      last_request_body: full_body,
      last_response_id: response_id,
      response_input: OpenAIResponseStream.output_items(state)
    }
  end

  defp continuation_metadata(_response_id, _full_body, _state), do: nil

  defp continuation_matches?(body, previous_body, prefix) do
    comparable_body(body) == comparable_body(previous_body) and
      input_prefix?(Map.get(body, :input, []), prefix)
  end

  defp delta_body(body, prefix, previous_response_id) do
    body
    |> Map.put(:input, Enum.drop(Map.get(body, :input, []), length(prefix)))
    |> Map.put(:previous_response_id, previous_response_id)
  end

  defp comparable_body(body), do: Map.drop(body, [:input, :previous_response_id])

  defp input_prefix?(list, prefix) when length(list) < length(prefix), do: false

  defp input_prefix?(list, prefix) do
    actual =
      list
      |> Enum.take(length(prefix))
      |> Enum.map(&comparable_input_item/1)

    expected = Enum.map(prefix, &comparable_input_item/1)

    actual == expected
  end

  defp comparable_input_item(items) when is_list(items) do
    Enum.map(items, &comparable_input_item/1)
  end

  defp comparable_input_item(%{} = item) do
    item
    |> Enum.map(fn {key, value} -> {to_string(key), comparable_input_item(value)} end)
    |> Map.new()
    |> maybe_drop_message_id()
  end

  defp comparable_input_item(value), do: value

  defp maybe_drop_message_id(%{"type" => "message"} = item), do: Map.delete(item, "id")
  defp maybe_drop_message_id(item), do: item

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
