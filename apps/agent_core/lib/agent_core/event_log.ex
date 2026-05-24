defmodule AgentCore.EventLog do
  @moduledoc """
  Appends agent events to a JSONL session log.

  Each line has `timestamp`, `event`, and `payload` fields. The logger subscribes
  to `AgentCore.EventBus` when it starts.
  """

  use GenServer

  defstruct [:io, :path]

  @doc """
  Starts a JSONL event logger.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Reads a JSONL event log into tuple events.

  Returns `{:error, {:invalid_log_line, line_number, reason}}` when a line
  cannot be decoded or does not map to a known event.
  """
  @spec read_events(Path.t()) :: {:ok, [AgentCore.Event.t()]} | {:error, term()}
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
    path = Keyword.fetch!(opts, :path)
    File.mkdir_p!(Path.dirname(path))

    with {:ok, io} <- File.open(path, [:append, :utf8]) do
      :ok = AgentCore.EventBus.subscribe()
      {:ok, %__MODULE__{io: io, path: path}}
    end
  end

  @impl true
  def handle_info({:agent_core_event, event}, state) do
    line =
      event
      |> AgentCore.Event.to_record()
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
         {:ok, event} <- AgentCore.Event.from_record(record) do
      decode_lines(rest, [event | events])
    else
      {:error, reason} -> {:error, {:invalid_log_line, line_number, reason}}
    end
  end
end
