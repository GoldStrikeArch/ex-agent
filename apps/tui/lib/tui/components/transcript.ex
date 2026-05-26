defmodule Tui.Components.Transcript do
  @moduledoc """
  Renders structured transcript blocks into viewport lines.

  Each visible line carries a style tag derived from its source block, so the
  transcript colorizes per block kind (assistant text, tool output, errors, and
  so on) rather than rendering one flat color.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Paragraph
  alias Tui.Components.Text
  alias Tui.TerminalApp.Transcript

  @doc """
  Returns plain viewport-ready transcript lines.
  """
  @spec lines(Transcript.t(), pos_integer(), pos_integer()) :: [String.t()]
  def lines(transcript, width, height) do
    transcript
    |> Transcript.visible_lines(width, height)
    |> Text.fill_lines(height)
  end

  @doc """
  Renders transcript lines as a paragraph of per-line styled spans.
  """
  @spec render(Transcript.t(), pos_integer(), pos_integer()) :: Paragraph.t()
  def render(transcript, width, height) do
    styled =
      transcript
      |> Transcript.visible_styled_lines(width, height)
      |> fill_styled(height)
      |> Enum.map(&styled_line/1)

    %Paragraph{text: styled, style: %Style{}}
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

  @doc """
  Width available for transcript text after reserving the scrollbar gutter.
  """
  @spec content_width(pos_integer()) :: pos_integer()
  defdelegate content_width(total_width), to: Transcript

  defp fill_styled(lines, height) do
    padding = max(0, height - length(lines))
    List.duplicate({:blank, ""}, padding) ++ lines
  end

  defp styled_line({tag, text}) do
    Line.new([Span.new(text, style: style_for(tag))])
  end

  defp style_for(:user), do: %Style{fg: :cyan, modifiers: [:bold]}
  defp style_for(:assistant), do: %Style{}
  defp style_for(:tool_header), do: %Style{fg: :green, modifiers: [:bold]}
  defp style_for(:tool_body), do: %Style{fg: :dark_gray}
  defp style_for(:permission), do: %Style{fg: :yellow, modifiers: [:bold]}
  defp style_for(:error), do: %Style{fg: :red, modifiers: [:bold]}
  defp style_for(:edit), do: %Style{fg: :magenta}
  defp style_for(:label), do: %Style{fg: :dark_gray}
  defp style_for(:system), do: %Style{fg: :dark_gray}
  defp style_for(_tag), do: %Style{}
end
