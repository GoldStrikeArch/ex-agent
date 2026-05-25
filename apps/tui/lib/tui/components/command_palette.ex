defmodule Tui.Components.CommandPalette do
  @moduledoc """
  Renders slash-command suggestions.
  """

  alias ExRatatui.Style
  alias Tui.Components.Text
  alias Tui.TerminalApp.CommandMenu

  @doc """
  Returns titled command palette lines for the current prompt.
  """
  @spec lines(String.t(), integer(), pos_integer()) :: [String.t()]
  def lines(prompt, selected_index, width) do
    prompt
    |> CommandMenu.lines(selected_index, width)
    |> Enum.take(6)
    |> case do
      [] -> []
      lines -> Text.titled_lines("commands", lines, width)
    end
  end

  @doc """
  Renders command palette lines as a paragraph.
  """
  @spec render(String.t(), integer(), pos_integer()) :: ExRatatui.Widgets.Paragraph.t()
  def render(prompt, selected_index, width) do
    prompt
    |> lines(selected_index, width)
    |> Text.paragraph(%Style{fg: :yellow, modifiers: [:bold]})
  end
end
