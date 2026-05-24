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
      |> event_record()
      |> AgentCore.Json.encode!()

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

  defp event_record(event) do
    [event_name | payload] = Tuple.to_list(event)

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: event_name,
      payload: payload
    }
  end
end
