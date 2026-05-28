defmodule Core.EventLog do
  @moduledoc """
  Appends agent events to a JSONL session log.

  Each line has `timestamp`, `event`, and `payload` fields. The logger subscribes
  to `Core.EventBus` when it starts.
  """

  use GenServer

  defstruct [:io, :path]

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
  Starts a JSONL event logger.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Returns the default JSONL event log path.

  The path is `$ELIXIR_AGENT_LOG_PATH` when set, otherwise
  `$ELIXIR_AGENT_DIR/logs/events.jsonl`, defaulting to
  `~/.elixir-agent/agent/logs/events.jsonl`.
  """
  @spec default_path(keyword()) :: Path.t()
  def default_path(opts \\ []) do
    Keyword.get(opts, :path) ||
      System.get_env("ELIXIR_AGENT_LOG_PATH") ||
      Path.join([agent_dir(opts), "logs", "events.jsonl"])
  end

  @doc """
  Reads a JSONL event log into tuple events.

  Returns `{:error, {:invalid_log_line, line_number, reason}}` when a line
  cannot be decoded or does not map to a known event.
  """
  @spec read_events(Path.t()) :: {:ok, [Core.Event.t()]} | {:error, term()}
  def read_events(path) do
    with {:ok, contents} <- File.read(path) do
      contents
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> decode_lines([])
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &default_path/0)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:append, :utf8]) do
      :ok = Core.EventBus.subscribe()
      {:ok, %__MODULE__{io: io, path: path}}
    else
      {:error, reason} ->
        if Keyword.get(opts, :required?, true) do
          {:stop, {:event_log_open_failed, path, reason}}
        else
          :ignore
        end
    end
  end

  @impl true
  def handle_info({:core_event, event}, state) do
    line =
      event
      |> Core.Event.to_record()
      |> json_safe()
      |> JSON.encode!()

    IO.write(state.io, [line, "\n"])

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.io do
      File.close(state.io)
    end

    :ok
  end

  defp decode_lines([], events), do: {:ok, Enum.reverse(events)}

  defp decode_lines([{line, line_number} | rest], events) do
    with {:ok, record} <- JSON.decode(line),
         {:ok, event} <- Core.Event.from_record(record) do
      decode_lines(rest, [event | events])
    else
      {:error, reason} -> {:error, {:invalid_log_line, line_number, reason}}
    end
  end

  defp agent_dir(opts) do
    Keyword.get(opts, :agent_dir) ||
      System.get_env("ELIXIR_AGENT_DIR") ||
      Path.join([System.user_home!(), ".elixir-agent", "agent"])
  end

  defp json_safe(value), do: json_safe_value(nil, value)

  defp json_safe_value(key, value) do
    if key_sensitive?(key) do
      "[redacted]"
    else
      do_json_safe(value)
    end
  end

  defp do_json_safe(value) when is_nil(value) or is_boolean(value), do: value
  defp do_json_safe(value) when is_binary(value), do: safe_string(value)
  defp do_json_safe(value) when is_number(value), do: value
  defp do_json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp do_json_safe(value) when is_pid(value), do: inspect(value)
  defp do_json_safe(value) when is_reference(value), do: inspect(value)
  defp do_json_safe(value) when is_function(value), do: inspect(value)
  defp do_json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp do_json_safe(%_module{} = value), do: inspect(value)

  defp do_json_safe(%{} = value) do
    value
    |> Enum.map(fn {key, item} -> {key_to_string(key), json_safe_value(key, item)} end)
    |> Map.new()
  end

  defp do_json_safe(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> json_safe()
  end

  defp do_json_safe(value), do: inspect(value)

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: inspect(key)

  defp key_sensitive?(nil), do: false

  defp key_sensitive?(key) do
    key
    |> key_to_string()
    |> String.downcase()
    |> then(&MapSet.member?(@sensitive_keys, &1))
  end

  defp safe_string(value) do
    if String.valid?(value) do
      value
    else
      inspect(value, charlists: :as_lists, limit: :infinity)
    end
  end
end
