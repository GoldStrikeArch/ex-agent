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

  # Braille spinner frames; all are one column wide so wrapping is unaffected.
  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @doc """
  Renders transcript lines as a paragraph of per-line styled spans.

  `spinner` is the current animation glyph prefixed onto running tool headers;
  it defaults to `""` (no spinner).
  """
  @spec render(Transcript.t(), pos_integer(), pos_integer(), String.t()) :: Paragraph.t()
  def render(transcript, width, height, spinner \\ "") do
    styled =
      transcript
      |> Transcript.visible_styled_lines(width, height, spinner)
      |> fill_styled(height)
      |> Enum.map(&styled_line/1)

    %Paragraph{text: styled, style: %Style{}}
  end

  @doc """
  Returns the spinner glyph for the given animation frame.
  """
  @spec spinner_glyph(non_neg_integer()) :: String.t()
  def spinner_glyph(frame) when is_integer(frame) and frame >= 0 do
    Enum.at(@spinner_frames, rem(frame, length(@spinner_frames)))
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
  defp style_for(:diff_add), do: %Style{fg: :green}
  defp style_for(:diff_del), do: %Style{fg: :red}
  defp style_for(:diff_hunk), do: %Style{fg: :cyan}
  defp style_for(:diff_context), do: %Style{fg: :dark_gray}
  defp style_for(:label), do: %Style{fg: :dark_gray}
  defp style_for(:system), do: %Style{fg: :dark_gray}
  defp style_for(_tag), do: %Style{}
end
