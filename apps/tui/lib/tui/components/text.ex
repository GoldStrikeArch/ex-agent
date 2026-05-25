defmodule Tui.Components.Text do
  @moduledoc """
  Shared text shaping helpers for terminal components.
  """

  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph

  @doc """
  Truncates a line to the visible terminal width.
  """
  @spec fit_line(String.t(), pos_integer()) :: String.t()
  def fit_line(line, width) when is_binary(line) do
    line
    |> String.graphemes()
    |> Enum.take(max(1, width))
    |> Enum.join()
  end

  @doc """
  Pads a line list at the top until it reaches the requested height.
  """
  @spec fill_lines([String.t()], non_neg_integer()) :: [String.t()]
  def fill_lines(lines, height) do
    padding = max(0, height - length(lines))
    List.duplicate("", padding) ++ lines
  end

  @doc """
  Adds a compact title row to component content.
  """
  @spec titled_lines(String.t(), [String.t()], pos_integer()) :: [String.t()]
  def titled_lines(title, lines, width) do
    [
      fit_line("[#{title}]", width)
      | Enum.map(lines, &fit_line(&1, width))
    ]
  end

  @doc """
  Builds a horizontal divider sized to terminal width.
  """
  @spec divider(pos_integer()) :: String.t()
  def divider(width), do: String.duplicate("-", max(1, width))

  @doc """
  Builds a paragraph from already-shaped component lines.
  """
  @spec paragraph([String.t()], Style.t()) :: Paragraph.t()
  def paragraph(lines, style) do
    %Paragraph{text: Enum.join(lines, "\n"), style: style}
  end
end
