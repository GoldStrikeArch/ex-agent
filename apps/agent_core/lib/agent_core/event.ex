defmodule AgentCore.Event do
  @moduledoc """
  Constructors and log conversion for the core event protocol.

  Events are intentionally plain tuples so renderers, JSONL logging, replay, and
  future adapters can consume the same boundary contract without depending on
  process internals.
  """

  @type role :: :user | :assistant | :system | :tool
  @type status :: :ok | :error | :cancelled | :timeout
  @type tool_args :: map()
  @type tool_summary :: String.t() | map()

  @type t ::
          {:session_started, map()}
          | {:user_message, String.t()}
          | {:assistant_message_started, String.t()}
          | {:assistant_delta, String.t(), String.t()}
          | {:assistant_message_finished, String.t()}
          | {:agent_started, String.t()}
          | {:agent_finished, String.t()}
          | {:turn_started, String.t()}
          | {:turn_finished, String.t(), map()}
          | {:message_started, String.t(), role()}
          | {:message_delta, String.t(), String.t()}
          | {:message_finished, map()}
          | {:tool_started, String.t(), String.t(), tool_args()}
          | {:tool_output, String.t(), String.t()}
          | {:tool_finished, String.t(), status(), tool_summary()}
          | {:batch_started, String.t(), non_neg_integer()}
          | {:batch_finished, String.t(), status()}
          | {:edit_preview, String.t(), Path.t(), String.t()}
          | {:edit_applied, String.t(), Path.t()}
          | {:validation_started, String.t()}
          | {:validation_finished, String.t(), integer(), String.t()}
          | {:permission_requested, String.t(), term()}
          | {:permission_resolved, String.t(), term()}
          | {:error, atom(), term()}
          | {:session_checkpointed, map()}

  @doc """
  Builds a `session_started` event.
  """
  @spec session_started(map()) :: t()
  def session_started(session_info), do: {:session_started, session_info}

  @doc """
  Builds a plan-compatible user message event.
  """
  @spec user_message(String.t()) :: t()
  def user_message(text), do: {:user_message, text}

  @doc """
  Builds a plan-compatible assistant message start event.
  """
  @spec assistant_message_started(String.t()) :: t()
  def assistant_message_started(message_id), do: {:assistant_message_started, message_id}

  @doc """
  Builds a plan-compatible assistant delta event.
  """
  @spec assistant_delta(String.t(), String.t()) :: t()
  def assistant_delta(message_id, text), do: {:assistant_delta, message_id, text}

  @doc """
  Builds a plan-compatible assistant message finish event.
  """
  @spec assistant_message_finished(String.t()) :: t()
  def assistant_message_finished(message_id), do: {:assistant_message_finished, message_id}

  @doc """
  Builds an agent lifecycle start event.
  """
  @spec agent_started(String.t()) :: t()
  def agent_started(session_id), do: {:agent_started, session_id}

  @doc """
  Builds an agent lifecycle finish event.
  """
  @spec agent_finished(String.t()) :: t()
  def agent_finished(session_id), do: {:agent_finished, session_id}

  @doc """
  Builds a turn start event.
  """
  @spec turn_started(String.t()) :: t()
  def turn_started(turn_id), do: {:turn_started, turn_id}

  @doc """
  Builds a turn finish event.
  """
  @spec turn_finished(String.t(), map()) :: t()
  def turn_finished(turn_id, summary), do: {:turn_finished, turn_id, summary}

  @doc """
  Builds a generic message start event.
  """
  @spec message_started(String.t(), role()) :: t()
  def message_started(message_id, role), do: {:message_started, message_id, role}

  @doc """
  Builds a generic message delta event.
  """
  @spec message_delta(String.t(), String.t()) :: t()
  def message_delta(message_id, text), do: {:message_delta, message_id, text}

  @doc """
  Builds a generic message finish event.
  """
  @spec message_finished(map()) :: t()
  def message_finished(message), do: {:message_finished, message}

  @doc """
  Builds a tool start event.
  """
  @spec tool_started(String.t(), String.t(), tool_args()) :: t()
  def tool_started(tool_call_id, name, args), do: {:tool_started, tool_call_id, name, args}

  @doc """
  Builds a tool output event.
  """
  @spec tool_output(String.t(), String.t()) :: t()
  def tool_output(tool_call_id, chunk), do: {:tool_output, tool_call_id, chunk}

  @doc """
  Builds a tool finish event.
  """
  @spec tool_finished(String.t(), status(), tool_summary()) :: t()
  def tool_finished(tool_call_id, status, result_summary) do
    {:tool_finished, tool_call_id, status, result_summary}
  end

  @doc """
  Builds a batch start event.
  """
  @spec batch_started(String.t(), non_neg_integer()) :: t()
  def batch_started(batch_id, count), do: {:batch_started, batch_id, count}

  @doc """
  Builds a batch finish event.
  """
  @spec batch_finished(String.t(), status()) :: t()
  def batch_finished(batch_id, status), do: {:batch_finished, batch_id, status}

  @doc """
  Builds an edit preview event.
  """
  @spec edit_preview(String.t(), Path.t(), String.t()) :: t()
  def edit_preview(edit_id, file_path, diff), do: {:edit_preview, edit_id, file_path, diff}

  @doc """
  Builds an edit applied event.
  """
  @spec edit_applied(String.t(), Path.t()) :: t()
  def edit_applied(edit_id, file_path), do: {:edit_applied, edit_id, file_path}

  @doc """
  Builds a validation start event.
  """
  @spec validation_started(String.t()) :: t()
  def validation_started(command), do: {:validation_started, command}

  @doc """
  Builds a validation finish event.
  """
  @spec validation_finished(String.t(), integer(), String.t()) :: t()
  def validation_finished(command, exit_status, summary) do
    {:validation_finished, command, exit_status, summary}
  end

  @doc """
  Builds a permission request event.
  """
  @spec permission_requested(String.t(), term()) :: t()
  def permission_requested(request_id, action), do: {:permission_requested, request_id, action}

  @doc """
  Builds a permission resolved event.
  """
  @spec permission_resolved(String.t(), term()) :: t()
  def permission_resolved(request_id, decision), do: {:permission_resolved, request_id, decision}

  @doc """
  Builds an error event.
  """
  @spec error(atom(), term()) :: t()
  def error(scope, reason), do: {:error, scope, reason}

  @doc """
  Builds a session checkpoint event.
  """
  @spec session_checkpointed(map()) :: t()
  def session_checkpointed(checkpoint_info), do: {:session_checkpointed, checkpoint_info}

  @doc """
  Converts an event into a JSONL-friendly map with a UTC timestamp.
  """
  @spec to_record(t()) :: map()
  def to_record(event) do
    to_record(event, DateTime.utc_now())
  end

  @doc """
  Converts an event into a JSONL-friendly map with an explicit timestamp.
  """
  @spec to_record(t(), DateTime.t()) :: map()
  def to_record(event, %DateTime{} = timestamp) when is_tuple(event) do
    [event_name | payload] = Tuple.to_list(event)

    %{
      timestamp: DateTime.to_iso8601(timestamp),
      event: Atom.to_string(event_name),
      payload: payload
    }
  end

  @doc """
  Converts a decoded JSONL record back into a tuple event.
  """
  @spec from_record(map()) :: {:ok, t()} | {:error, term()}
  def from_record(%{"event" => event_name, "payload" => payload}) when is_list(payload) do
    with {:ok, event_atom} <- event_atom(event_name) do
      payload = normalize_payload(event_atom, payload)
      {:ok, List.to_tuple([event_atom | payload])}
    end
  end

  def from_record(%{event: event_name, payload: payload}) when is_list(payload) do
    from_record(%{"event" => event_name, "payload" => payload})
  end

  def from_record(record), do: {:error, {:invalid_event_record, record}}

  defp event_atom("session_started"), do: {:ok, :session_started}
  defp event_atom("user_message"), do: {:ok, :user_message}
  defp event_atom("assistant_message_started"), do: {:ok, :assistant_message_started}
  defp event_atom("assistant_delta"), do: {:ok, :assistant_delta}
  defp event_atom("assistant_message_finished"), do: {:ok, :assistant_message_finished}
  defp event_atom("agent_started"), do: {:ok, :agent_started}
  defp event_atom("agent_finished"), do: {:ok, :agent_finished}
  defp event_atom("turn_started"), do: {:ok, :turn_started}
  defp event_atom("turn_finished"), do: {:ok, :turn_finished}
  defp event_atom("message_started"), do: {:ok, :message_started}
  defp event_atom("message_delta"), do: {:ok, :message_delta}
  defp event_atom("message_finished"), do: {:ok, :message_finished}
  defp event_atom("tool_started"), do: {:ok, :tool_started}
  defp event_atom("tool_output"), do: {:ok, :tool_output}
  defp event_atom("tool_finished"), do: {:ok, :tool_finished}
  defp event_atom("batch_started"), do: {:ok, :batch_started}
  defp event_atom("batch_finished"), do: {:ok, :batch_finished}
  defp event_atom("edit_preview"), do: {:ok, :edit_preview}
  defp event_atom("edit_applied"), do: {:ok, :edit_applied}
  defp event_atom("validation_started"), do: {:ok, :validation_started}
  defp event_atom("validation_finished"), do: {:ok, :validation_finished}
  defp event_atom("permission_requested"), do: {:ok, :permission_requested}
  defp event_atom("permission_resolved"), do: {:ok, :permission_resolved}
  defp event_atom("error"), do: {:ok, :error}
  defp event_atom("session_checkpointed"), do: {:ok, :session_checkpointed}
  defp event_atom(name), do: {:error, {:unknown_event, name}}

  defp normalize_payload(:message_started, [message_id, role]) do
    [message_id, known_atom(role, [:user, :assistant, :system, :tool])]
  end

  defp normalize_payload(:tool_finished, [tool_call_id, status, summary]) do
    [
      tool_call_id,
      known_atom(status, [:ok, :error, :cancelled, :timeout]),
      normalize_decoded_term(summary)
    ]
  end

  defp normalize_payload(:batch_finished, [batch_id, status]) do
    [batch_id, known_atom(status, [:ok, :error, :cancelled, :timeout])]
  end

  defp normalize_payload(:error, [scope, reason]) do
    [
      known_atom(scope, [:model, :tool, :session, :validation, :permission]),
      normalize_decoded_term(reason)
    ]
  end

  defp normalize_payload(_event_atom, payload) do
    Enum.map(payload, &normalize_decoded_term/1)
  end

  defp normalize_decoded_term(%{} = value) do
    value
    |> Enum.map(fn {key, item} -> {normalize_key(key), normalize_value(key, item)} end)
    |> Map.new()
  end

  defp normalize_decoded_term(value) when is_list(value),
    do: Enum.map(value, &normalize_decoded_term/1)

  defp normalize_decoded_term(value), do: normalize_value(nil, value)

  defp normalize_value(_key, %{} = value), do: normalize_decoded_term(value)

  defp normalize_value(_key, value) when is_list(value),
    do: Enum.map(value, &normalize_decoded_term/1)

  defp normalize_value(key, value) when key in ["role", :role],
    do: known_atom(value, [:user, :assistant, :system, :tool])

  defp normalize_value(key, value) when key in ["status", :status],
    do: known_atom(value, [:ok, :error, :cancelled, :timeout])

  defp normalize_value(key, value) when key in ["safety", :safety],
    do: known_atom(value, [:read_only, :write, :shell, :risky])

  defp normalize_value(_key, value) when is_binary(value), do: value

  defp normalize_value(_key, value), do: value

  defp known_atom(value, allowed) when is_binary(value) do
    Enum.find(allowed, value, &(Atom.to_string(&1) == value))
  end

  defp known_atom(value, _allowed), do: value

  defp normalize_key("args"), do: :args
  defp normalize_key("bytes"), do: :bytes
  defp normalize_key("column"), do: :column
  defp normalize_key("content"), do: :content
  defp normalize_key("count"), do: :count
  defp normalize_key("entries"), do: :entries
  defp normalize_key("file"), do: :file
  defp normalize_key("id"), do: :id
  defp normalize_key("line"), do: :line
  defp normalize_key("matches"), do: :matches
  defp normalize_key("message_id"), do: :message_id
  defp normalize_key("name"), do: :name
  defp normalize_key("output"), do: :output
  defp normalize_key("path"), do: :path
  defp normalize_key("reason"), do: :reason
  defp normalize_key("role"), do: :role
  defp normalize_key("safety"), do: :safety
  defp normalize_key("session_id"), do: :session_id
  defp normalize_key("status"), do: :status
  defp normalize_key("summary"), do: :summary
  defp normalize_key("text"), do: :text
  defp normalize_key("tool_call_id"), do: :tool_call_id
  defp normalize_key("tool_calls"), do: :tool_calls
  defp normalize_key("truncated"), do: :truncated
  defp normalize_key("type"), do: :type
  defp normalize_key(key), do: key
end
