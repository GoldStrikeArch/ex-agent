defmodule Tui.Replay do
  @moduledoc """
  Replays JSONL event logs through the text renderer.
  """

  @event_atoms %{
    "session_started" => :session_started,
    "user_message" => :user_message,
    "assistant_message_started" => :assistant_message_started,
    "assistant_delta" => :assistant_delta,
    "assistant_message_finished" => :assistant_message_finished,
    "agent_started" => :agent_started,
    "agent_finished" => :agent_finished,
    "turn_started" => :turn_started,
    "turn_finished" => :turn_finished,
    "message_started" => :message_started,
    "message_delta" => :message_delta,
    "message_finished" => :message_finished,
    "model_request" => :model_request,
    "model_response" => :model_response,
    "tool_started" => :tool_started,
    "tool_output" => :tool_output,
    "tool_finished" => :tool_finished,
    "batch_started" => :batch_started,
    "batch_finished" => :batch_finished,
    "edit_preview" => :edit_preview,
    "edit_applied" => :edit_applied,
    "validation_started" => :validation_started,
    "validation_finished" => :validation_finished,
    "permission_requested" => :permission_requested,
    "permission_resolved" => :permission_resolved,
    "error" => :error,
    "session_checkpointed" => :session_checkpointed
  }

  @role_atoms %{"user" => :user, "assistant" => :assistant, "system" => :system, "tool" => :tool}
  @status_atoms %{
    "ok" => :ok,
    "error" => :error,
    "cancelled" => :cancelled,
    "timeout" => :timeout
  }
  @error_scope_atoms %{
    "model" => :model,
    "tool" => :tool,
    "session" => :session,
    "validation" => :validation,
    "permission" => :permission
  }

  @doc """
  Renders a JSONL event log to an IO device.
  """
  @spec render_file(Path.t(), keyword()) :: :ok | {:error, term()}
  def render_file(path, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)

    with {:ok, events} <- read_events(path) do
      Enum.each(events, &IO.write(io, Tui.TextRenderer.render(&1)))
      :ok
    end
  end

  defp read_events(path) do
    with {:ok, contents} <- File.read(path) do
      contents
      |> String.split("\n", trim: true)
      |> parse_lines([])
    end
  end

  defp parse_lines([], events), do: {:ok, Enum.reverse(events)}

  defp parse_lines([line | rest], events) do
    with {:ok, record} <- JSON.decode(line),
         {:ok, event} <- event_from_record(record) do
      parse_lines(rest, [event | events])
    end
  end

  defp event_from_record(%{"event" => event_name, "payload" => payload}) when is_list(payload) do
    with {:ok, event_atom} <- known_atom(event_name, @event_atoms) do
      payload =
        payload
        |> normalize_payload(event_atom)

      {:ok, List.to_tuple([event_atom | payload])}
    end
  end

  defp event_from_record(record), do: {:error, {:invalid_event_record, record}}

  defp normalize_payload(payload, :message_started) do
    normalize_role_payload(payload)
  end

  defp normalize_payload(payload, :tool_finished) do
    normalize_status_payload(payload, 1)
  end

  defp normalize_payload(payload, :batch_finished) do
    normalize_status_payload(payload, 1)
  end

  defp normalize_payload(payload, :error) do
    normalize_status_payload(payload, 0, @error_scope_atoms)
  end

  defp normalize_payload(payload, _event_atom) do
    Enum.map(payload, &normalize_value/1)
  end

  defp normalize_role_payload([message_id, role]) do
    [message_id, known_atom!(role, @role_atoms)]
  end

  defp normalize_status_payload(payload, index, known_atoms \\ @status_atoms) do
    payload
    |> Enum.with_index()
    |> Enum.map(fn {value, current_index} ->
      if current_index == index, do: known_atom!(value, known_atoms), else: normalize_value(value)
    end)
  end

  defp normalize_value(%{} = value) do
    value
    |> Enum.map(fn {key, item} ->
      key = normalize_key(key)
      {key, normalize_map_value(key, item)}
    end)
    |> Map.new()
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_map_value(:role, value), do: known_atom!(value, @role_atoms)
  defp normalize_map_value(:status, value), do: known_atom!(value, @status_atoms)
  defp normalize_map_value(_key, value), do: normalize_value(value)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("id"), do: :id
  defp normalize_key("name"), do: :name
  defp normalize_key("path"), do: :path
  defp normalize_key("pattern"), do: :pattern
  defp normalize_key("reason"), do: :reason
  defp normalize_key("role"), do: :role
  defp normalize_key("content"), do: :content
  defp normalize_key("status"), do: :status
  defp normalize_key("summary"), do: :summary
  defp normalize_key("session_id"), do: :session_id
  defp normalize_key(key), do: key

  defp known_atom!(value, known_atoms) do
    case known_atom(value, known_atoms) do
      {:ok, atom} -> atom
      {:error, _reason} -> value
    end
  end

  defp known_atom(value, known_atoms) when is_binary(value) do
    case Map.fetch(known_atoms, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:unknown_atom, value}}
    end
  end

  defp known_atom(value, _known_atoms) when is_atom(value), do: {:ok, value}
end
