defmodule Core.ModelTrace do
  @moduledoc """
  Builds compact diagnostics for model calls.

  The trace payloads are meant for session logs, not for replaying provider
  traffic byte-for-byte. They keep message order, tool arguments, model options,
  and final model results visible while truncating large text fields and
  redacting obvious credentials before events reach the log writer.
  """

  @content_limit 12_000
  @inspect_limit 2_000

  @sensitive_keys MapSet.new(~w(
                      access
                      api_key
                      authorization
                      cookie
                      credential
                      credential_resolver
                      headers
                      password
                      refresh
                      secret
                      set-cookie
                      sse_headers
                      token
                      websocket_headers
                    ))

  @doc """
  Builds a compact payload for a model request.
  """
  @spec request(map(), [Core.AgentSession.message()], [map()], keyword(), non_neg_integer()) ::
          map()
  def request(spec, messages, tool_schemas, model_opts, iteration) do
    %{
      session_id: spec.session_id,
      turn_id: spec.turn_id,
      iteration: iteration,
      model_client: inspect(spec.model_client),
      model_opts: compact_keyword(model_opts),
      message_count: length(messages),
      messages: Enum.map(messages, &message/1),
      tool_count: length(tool_schemas),
      tools: Enum.map(tool_schemas, &tool_schema/1)
    }
  end

  @doc """
  Builds a compact payload for a model response or model error.
  """
  @spec response({:ok, Core.ModelClient.response()} | {:error, term()}) :: map()
  def response({:ok, response}) do
    %{status: :ok, response: model_response(response)}
  end

  def response({:error, reason}) do
    %{status: :error, reason: compact_term(reason)}
  end

  @doc """
  Converts an arbitrary term into a compact, log-friendly value.
  """
  @spec compact_term(term()) :: term()
  def compact_term(term), do: compact_value(nil, term)

  defp message(%{role: role} = message) do
    %{
      role: role,
      content: content_summary(Map.get(message, :content, ""))
    }
    |> maybe_put(:id, Map.get(message, :id))
    |> maybe_put(:name, Map.get(message, :name))
    |> maybe_put(:status, Map.get(message, :status))
    |> maybe_put(:summary, summary(message))
    |> maybe_put(:tool_call_id, Map.get(message, :tool_call_id))
    |> maybe_put(:tool_calls, tool_calls(Map.get(message, :tool_calls)))
  end

  defp message(message) do
    %{invalid_message: compact_term(message)}
  end

  defp summary(%{summary: summary}) when is_binary(summary), do: content_summary(summary)
  defp summary(_message), do: nil

  defp tool_calls(nil), do: nil
  defp tool_calls([]), do: []
  defp tool_calls(calls) when is_list(calls), do: Enum.map(calls, &tool_call/1)
  defp tool_calls(calls), do: compact_term(calls)

  defp tool_call(%{id: id, name: name, args: args} = call) do
    %{
      id: id,
      name: name,
      args: compact_value(:args, args)
    }
    |> maybe_put(:provider_id, Map.get(call, :provider_id))
  end

  defp tool_call(call), do: compact_term(call)

  defp tool_schema(%{} = schema) do
    %{
      name: Map.get(schema, :name, Map.get(schema, "name")),
      description:
        content_summary(Map.get(schema, :description, Map.get(schema, "description", ""))),
      safety: Map.get(schema, :safety, Map.get(schema, "safety")),
      schema: compact_value(:schema, Map.get(schema, :schema, Map.get(schema, "schema", %{})))
    }
  end

  defp tool_schema(schema), do: compact_term(schema)

  defp model_response(content) when is_binary(content) do
    %{content: content_summary(content), tool_calls: []}
  end

  defp model_response(%{} = response) do
    %{
      content: content_summary(response_content(response)),
      tool_calls: tool_calls(Map.get(response, :tool_calls, Map.get(response, "tool_calls", [])))
    }
  end

  defp model_response(response), do: compact_term(response)

  defp response_content(%{content: content}) when is_binary(content), do: content
  defp response_content(%{"content" => content}) when is_binary(content), do: content
  defp response_content(_response), do: ""

  defp compact_keyword(opts) do
    opts
    |> Enum.map(fn {key, value} -> {key, compact_value(key, value)} end)
    |> Map.new()
  end

  defp compact_value(key, value) do
    if key_sensitive?(key) do
      "[redacted]"
    else
      do_compact_value(value)
    end
  end

  defp do_compact_value(value) when is_binary(value), do: compact_string(value)
  defp do_compact_value(value) when is_nil(value) or is_boolean(value), do: value
  defp do_compact_value(value) when is_number(value), do: value
  defp do_compact_value(value) when is_atom(value), do: value

  defp do_compact_value(value) when is_list(value),
    do: Enum.map(value, &compact_value(nil, &1))

  defp do_compact_value(%_module{} = value), do: inspect_summary(value)

  defp do_compact_value(%{} = value) do
    value
    |> Enum.map(fn {key, item} -> {key, compact_value(key, item)} end)
    |> Map.new()
  end

  defp do_compact_value(value) when is_tuple(value),
    do: compact_value(nil, Tuple.to_list(value))

  defp do_compact_value(value), do: inspect_summary(value)

  defp content_summary(value) when is_binary(value) do
    text = safe_string(value)

    %{
      text: truncate(text, @content_limit),
      bytes: byte_size(value),
      truncated: byte_size(text) > @content_limit
    }
  end

  defp compact_string(value) when byte_size(value) <= @content_limit do
    safe_string(value)
  end

  defp compact_string(value), do: content_summary(value)

  defp inspect_summary(value) do
    value
    |> inspect(charlists: :as_lists, limit: 50)
    |> truncate(@inspect_limit)
  end

  defp truncate(value, limit) when byte_size(value) <= limit, do: value

  defp truncate(value, limit) do
    value
    |> String.to_charlist()
    |> Enum.take(limit)
    |> List.to_string()
    |> Kernel.<>("\n...[truncated]")
  end

  defp safe_string(value) do
    if String.valid?(value) do
      value
    else
      inspect(value, charlists: :as_lists, limit: :infinity, printable_limit: @content_limit)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp key_sensitive?(nil), do: false

  defp key_sensitive?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(&MapSet.member?(@sensitive_keys, &1))
  end
end
