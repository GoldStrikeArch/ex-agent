defmodule Tui.TerminalApp.Transcript do
  @moduledoc """
  Maintains the visible transcript as completed lines plus the active line.

  `Tui.TextRenderer` remains the canonical event-to-text renderer. This
  module only stores its append-only output in a shape that is cheap to trim for
  a viewport.
  """

  defstruct completed: [], current: "", max_completed: 1_000

  @type t :: %__MODULE__{
          completed: [String.t()],
          current: String.t(),
          max_completed: pos_integer()
        }

  @doc """
  Builds an empty transcript.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{max_completed: Keyword.get(opts, :max_completed, 1_000)}
  end

  @doc """
  Appends one agent event to the transcript.
  """
  @spec append_event(t(), tuple()) :: t()
  def append_event(%__MODULE__{} = transcript, event) do
    event
    |> Tui.TextRenderer.render()
    |> IO.iodata_to_binary()
    |> append_text(transcript)
  end

  @doc """
  Appends already-rendered text to the transcript.
  """
  @spec append_text(String.t(), t()) :: t()
  def append_text("", %__MODULE__{} = transcript), do: transcript

  def append_text(text, %__MODULE__{} = transcript) when is_binary(text) do
    case String.split(text, "\n") do
      [line] ->
        %{transcript | current: transcript.current <> line}

      [first | rest] ->
        rest
        |> Enum.reduce(%{transcript | current: transcript.current <> first}, fn segment, acc ->
          %{acc | completed: [acc.current | acc.completed], current: segment}
        end)
        |> trim_completed()
    end
  end

  @doc """
  Returns viewport-ready transcript lines.
  """
  @spec visible_lines(t(), pos_integer(), pos_integer()) :: [String.t()]
  def visible_lines(%__MODULE__{} = transcript, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    transcript
    |> all_lines()
    |> Enum.flat_map(&fit_line(&1, width))
    |> Enum.take(-height)
  end

  def visible_lines(%__MODULE__{}, _width, _height), do: []

  @doc """
  Clears the transcript.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = transcript) do
    %{transcript | completed: [], current: ""}
  end

  defp all_lines(%{completed: completed, current: ""}) do
    Enum.reverse(completed)
  end

  defp all_lines(%{completed: completed, current: current}) do
    completed
    |> Enum.reverse()
    |> Kernel.++([current])
  end

  defp fit_line("", _width), do: [""]

  defp fit_line(line, width) do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp trim_completed(%{completed: completed, max_completed: max_completed} = transcript)
       when length(completed) > max_completed do
    trimmed =
      completed
      |> Enum.take(max_completed)

    %{transcript | completed: trimmed}
  end

  defp trim_completed(transcript), do: transcript
end
