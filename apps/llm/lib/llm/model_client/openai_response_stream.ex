defmodule LLM.ModelClient.OpenAIResponseStream do
  @moduledoc false

  @type state :: %{
          required(:sse) => Network.SSE.t(),
          required(:content) => String.t(),
          required(:tool_calls) => map(),
          required(:response_id) => String.t() | nil,
          required(:output_items) => [map()]
        }

  @doc false
  @spec initial_state() :: state()
  def initial_state do
    %{sse: Network.SSE.new(), content: "", tool_calls: %{}, response_id: nil, output_items: []}
  end

  @doc false
  @spec from_events([map()], (String.t() -> any())) ::
          {:ok, Core.ModelClient.response()} | {:error, term()}
  def from_events(events, event_sink) when is_list(events) and is_function(event_sink, 1) do
    events
    |> from_events_with_state(event_sink)
    |> case do
      {:ok, response, _state} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec from_events_with_state([map()], (String.t() -> any())) ::
          {:ok, Core.ModelClient.response(), state()} | {:error, term()}
  def from_events_with_state(events, event_sink)
      when is_list(events) and is_function(event_sink, 1) do
    events
    |> Enum.reduce_while({:ok, initial_state()}, &reduce_event(event_sink, &1, &2))
    |> finish_with_state()
  end

  @doc false
  @spec parse_chunk(binary(), state(), (String.t() -> any())) :: {:ok, state()} | {:error, term()}
  def parse_chunk("", state, _event_sink), do: {:ok, state}

  def parse_chunk(chunk, state, event_sink) do
    with {:ok, payloads, sse} <- Network.SSE.parse_chunk(state.sse, chunk) do
      reduce_sse_payloads(payloads, %{state | sse: sse}, event_sink)
    end
  end

  @doc false
  @spec parse_event(map(), state(), (String.t() -> any())) :: {:ok, state()} | {:error, term()}
  def parse_event(event, state, event_sink) when is_map(event) and is_function(event_sink, 1) do
    case reduce_event(event_sink, event, {:ok, state}) do
      {:cont, result} -> result
      {:halt, result} -> result
    end
  end

  @doc false
  @spec flush({:ok, state()} | {:error, term()}, (String.t() -> any())) ::
          {:ok, state()} | {:error, term()}
  def flush({:ok, state}, event_sink) do
    with {:ok, payloads, sse} <- Network.SSE.flush(state.sse) do
      reduce_sse_payloads(payloads, %{state | sse: sse}, event_sink)
    end
  end

  def flush({:error, reason}, _event_sink), do: {:error, reason}

  @doc false
  @spec finish({:ok, state()} | {:error, term()}) ::
          {:ok, Core.ModelClient.response()} | {:error, term()}
  def finish({:ok, state}) do
    with {:ok, tool_calls} <- normalize_tool_calls(state.tool_calls) do
      case tool_calls do
        [] -> {:ok, state.content}
        calls -> {:ok, %{content: state.content, tool_calls: calls}}
      end
    end
  end

  def finish({:error, reason}), do: {:error, reason}

  @doc false
  @spec finish_with_state({:ok, state()} | {:error, term()}) ::
          {:ok, Core.ModelClient.response(), state()} | {:error, term()}
  def finish_with_state({:ok, state}) do
    case finish({:ok, state}) do
      {:ok, response} -> {:ok, response, state}
      {:error, reason} -> {:error, reason}
    end
  end

  def finish_with_state({:error, reason}), do: {:error, reason}

  @doc false
  @spec response_id(state()) :: String.t() | nil
  def response_id(state), do: state.response_id

  @doc false
  @spec output_items(state()) :: [map()]
  def output_items(state), do: Enum.reverse(state.output_items)

  @doc false
  @spec completed?(map()) :: boolean()
  def completed?(event), do: event_type(event) == "response.completed"

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

      "response.completed" ->
        {:cont, {:ok, finish_response(state, event)}}

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

  defp finish_output_item(state, %{"item" => item} = event) do
    state
    |> store_output_item(item)
    |> maybe_finish_tool_call(item, event)
  end

  defp finish_output_item(state, _event), do: state

  defp store_output_item(state, %{"type" => "function_call_output"}), do: state
  defp store_output_item(state, item), do: %{state | output_items: [item | state.output_items]}

  defp maybe_finish_tool_call(state, %{"type" => "function_call"} = item, event) do
    update_in(state, [:tool_calls, output_index(event)], &finish_tool_call(&1, item))
  end

  defp maybe_finish_tool_call(state, _item, _event), do: state

  defp finish_tool_call(tool_call, item) do
    base = tool_call || %{}

    base
    |> Map.put(:id, Map.get(item, "call_id"))
    |> Map.put(:provider_id, Map.get(item, "id"))
    |> Map.put(:name, Map.get(item, "name"))
    |> Map.put(:arguments, Map.get(item, "arguments", Map.get(base, :arguments, "")))
  end

  defp finish_response(state, event) do
    response = Map.get(event, "response", %{})
    response_id = Map.get(response, "id") || state.response_id
    output_items = response_output_items(response, state.output_items)
    %{state | response_id: response_id, output_items: output_items}
  end

  defp response_output_items(%{"output" => output}, _current) when is_list(output) do
    output
    |> Enum.reject(&(Map.get(&1, "type") == "function_call_output"))
    |> Enum.reverse()
  end

  defp response_output_items(_response, current), do: current

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
end
