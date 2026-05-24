defmodule Network.SSE do
  @moduledoc """
  Incremental parser for Server-Sent Events data frames.

  The parser only understands SSE framing. Provider-specific data payloads,
  such as JSON decoding or `[DONE]` sentinels, should be handled by callers.
  """

  @enforce_keys [:buffer]
  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: String.t()}

  @doc """
  Returns a new parser state.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{buffer: ""}

  @doc """
  Parses a chunk and returns completed `data:` payloads plus the next state.
  """
  @spec parse_chunk(t(), binary()) :: {:ok, [String.t()], t()}
  def parse_chunk(%__MODULE__{} = state, ""), do: {:ok, [], state}

  def parse_chunk(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    {events, partial} =
      state.buffer
      |> Kernel.<>(chunk)
      |> split_events()

    {:ok, event_data(events), %{state | buffer: partial}}
  end

  @doc """
  Flushes a final partial frame.
  """
  @spec flush(t()) :: {:ok, [String.t()], t()}
  def flush(%__MODULE__{buffer: buffer} = state) do
    if String.trim(buffer) == "" do
      {:ok, [], %{state | buffer: ""}}
    else
      {:ok, event_data([buffer]), %{state | buffer: ""}}
    end
  end

  defp split_events(buffer) do
    case String.split(buffer, "\n\n", trim: false) do
      [] -> {[], ""}
      [partial] -> {[], partial}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp event_data(events) do
    events
    |> Enum.map(&data_payload/1)
    |> Enum.reject(&is_nil/1)
  end

  defp data_payload(event) do
    data =
      event
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn "data:" <> data -> String.trim_leading(data) end)
      |> String.trim()

    if data == "", do: nil, else: data
  end
end
