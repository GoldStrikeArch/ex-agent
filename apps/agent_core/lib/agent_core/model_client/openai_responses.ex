defmodule AgentCore.ModelClient.OpenAIResponses do
  @moduledoc """
  OpenAI Responses API model client.

  The client keeps transcript state local. Each call sends the full local input
  list to the provider and returns either final assistant text or normalized tool
  calls for `AgentCore.AgentSession` to execute.
  """

  @behaviour AgentCore.ModelClient

  alias AgentCore.Auth.OAuth.OpenAICodex

  @openai_base_url "https://api.openai.com/v1"
  @codex_base_url "https://chatgpt.com/backend-api"
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
  @spec build_request([AgentCore.AgentSession.message()], [map()], keyword()) ::
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
         timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms)
       }}
    end
  end

  @doc false
  @spec from_events([map()], (String.t() -> any())) ::
          {:ok, AgentCore.ModelClient.response()} | {:error, term()}
  def from_events(events, event_sink) when is_list(events) and is_function(event_sink, 1) do
    events
    |> Enum.reduce_while({:ok, initial_stream_state()}, &reduce_event(event_sink, &1, &2))
    |> finish_stream_state()
  end

  defp stream_request(request, event_sink) do
    parent = self()
    chunk_ref = make_ref()

    with {:ok, worker} <- start_stream_worker(parent, chunk_ref, request) do
      collect_stream(worker, chunk_ref, initial_stream_state(), event_sink, request.timeout_ms)
    end
  end

  defp start_stream_worker(parent, chunk_ref, request) do
    result_ref = make_ref()

    case Task.Supervisor.start_child(AgentCore.ToolTaskSupervisor, fn ->
           result = post_stream_request(request, parent, chunk_ref)
           send(parent, {result_ref, result})
         end) do
      {:ok, pid} -> {:ok, stream_worker(pid, result_ref)}
      {:ok, pid, _info} -> {:ok, stream_worker(pid, result_ref)}
      {:error, reason} -> {:error, {:stream_worker_unavailable, reason}}
    end
  end

  defp stream_worker(pid, result_ref) do
    %{pid: pid, monitor_ref: Process.monitor(pid), result_ref: result_ref}
  end

  defp post_stream_request(request, parent, chunk_ref) do
    Req.post(
      url: request.url,
      headers: request.headers,
      json: request.body,
      receive_timeout: request.timeout_ms,
      into: fn {:data, data}, acc ->
        send(parent, {chunk_ref, :chunk, data})
        {:cont, acc}
      end
    )
  end

  defp collect_stream(worker, chunk_ref, state, event_sink, timeout_ms) do
    %{monitor_ref: monitor_ref, result_ref: result_ref} = worker

    receive do
      {^chunk_ref, :chunk, chunk} ->
        handle_stream_chunk(chunk, worker, chunk_ref, state, event_sink, timeout_ms)

      {^result_ref, result} ->
        handle_stream_result(result, worker, state, event_sink)

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:error, {:openai_request_failed, reason}}
    after
      timeout_ms ->
        stop_worker(worker, :timeout)
    end
  end

  defp handle_stream_chunk(chunk, worker, chunk_ref, state, event_sink, timeout_ms) do
    case parse_chunk(chunk, state, event_sink) do
      {:ok, next_state} -> collect_stream(worker, chunk_ref, next_state, event_sink, timeout_ms)
      {:error, reason} -> stop_worker(worker, reason)
    end
  end

  defp handle_stream_result(result, worker, state, event_sink) do
    Process.demonitor(worker.monitor_ref, [:flush])
    finish_stream_result(result, state, event_sink)
  end

  defp finish_stream_result({:ok, %{status: status, body: body}}, state, event_sink)
       when status in 200..299 do
    state
    |> parse_chunk(to_string(body), event_sink)
    |> flush_buffer(event_sink)
    |> finish_stream_state()
  end

  defp finish_stream_result({:ok, %{status: status, body: body}}, _state, _event_sink) do
    {:error, {:openai_response_failed, status, body}}
  end

  defp finish_stream_result({:error, reason}, _state, _event_sink) do
    {:error, {:openai_request_failed, reason}}
  end

  defp stop_worker(%{pid: pid, monitor_ref: monitor_ref}, reason) do
    Process.exit(pid, :kill)
    Process.demonitor(monitor_ref, [:flush])
    {:error, reason}
  end

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
    with {:ok, credential} <- OpenAICodex.resolve_credential(opts) do
      {:ok,
       %{
         provider: :openai_codex,
         token: credential.access,
         account_id: credential.account_id
       }}
    end
  end

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
      {"originator", "elixir-agent"},
      {"user-agent", "elixir-agent"},
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
    |> maybe_put(:tools, tool_schemas(tools))
    |> maybe_put(:reasoning, reasoning(opts))
  end

  defp message_to_input({%{role: :user, content: content}, _index}) do
    [%{role: "user", content: content}]
  end

  defp message_to_input({%{role: :system, content: content}, _index}) do
    [%{role: "system", content: content}]
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

  defp initial_stream_state do
    %{buffer: "", content: "", tool_calls: %{}}
  end

  defp parse_chunk("", state, _event_sink), do: {:ok, state}

  defp parse_chunk(chunk, state, event_sink) do
    (state.buffer <> chunk)
    |> split_sse_events()
    |> reduce_sse_events(%{state | buffer: ""}, event_sink)
  end

  defp flush_buffer({:ok, %{buffer: buffer} = state}, event_sink) do
    if String.trim(buffer) == "" do
      {:ok, %{state | buffer: ""}}
    else
      reduce_sse_events({[buffer], ""}, %{state | buffer: ""}, event_sink)
    end
  end

  defp flush_buffer({:error, reason}, _event_sink), do: {:error, reason}

  defp split_sse_events(buffer) do
    case String.split(buffer, "\n\n", trim: false) do
      [] -> {[], ""}
      [partial] -> {[], partial}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp reduce_sse_events({events, partial}, state, event_sink) do
    state = %{state | buffer: partial}

    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, next_state} ->
      case parse_sse_event(event) do
        {:ok, nil} -> {:cont, {:ok, next_state}}
        {:ok, parsed} -> reduce_event(event_sink, parsed, {:ok, next_state})
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_sse_event(event) do
    data =
      event
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn "data:" <> data -> String.trim_leading(data) end)
      |> String.trim()

    cond do
      data in ["", "[DONE]"] -> {:ok, nil}
      true -> JSON.decode(data)
    end
  end

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
           AgentCore.ToolCall.normalize(%{
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
