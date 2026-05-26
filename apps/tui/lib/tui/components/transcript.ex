defmodule Tui.Components.Transcript do
  @moduledoc """
  Renders structured transcript blocks into viewport lines.
  """

  alias ExRatatui.Style
  alias Tui.Components.Text
  alias Tui.TerminalApp.Transcript

  @doc """
  Returns viewport-ready transcript lines.
  """
  @spec lines(Transcript.t(), pos_integer(), pos_integer()) :: [String.t()]
  def lines(transcript, width, height) do
    transcript
    |> Transcript.visible_lines(width, height)
    |> Text.fill_lines(height)
  end

  @doc """
  Renders transcript lines as a paragraph.
  """
  @spec render(Transcript.t(), pos_integer(), pos_integer()) :: ExRatatui.Widgets.Paragraph.t()
  def render(transcript, width, height) do
    transcript
    |> lines(width, height)
    |> Text.paragraph(%Style{})
  end

  @doc """
  Returns scroll metrics (content length, position, viewport) for the indicator.
  """
  @spec viewport_metrics(Transcript.t(), pos_integer(), pos_integer()) :: %{
          content_length: non_neg_integer(),
          position: non_neg_integer(),
          viewport: pos_integer()
        }
  defdelegate viewport_metrics(transcript, width, height), to: Transcript
end
