defmodule Tui.Components.Panel do
  @moduledoc """
  Renders lightweight help and status panels.
  """

  alias ExRatatui.Style
  alias Tui.Components.Text
  alias Tui.TerminalApp.CommandMenu
  alias Tui.TerminalApp.Status

  @doc """
  Returns titled panel lines for the active panel.
  """
  @spec lines(:help | :status | nil, Status.t(), pos_integer()) :: [String.t()]
  def lines(nil, _status, _width), do: []

  def lines(:help, _status, width) do
    Text.titled_lines("commands", CommandMenu.help_lines(), width)
  end

  def lines(:status, status, width) do
    Text.titled_lines("status", Status.panel_lines(status), width)
  end

  @doc """
  Renders the active panel as a paragraph.
  """
  @spec render(:help | :status | nil, Status.t(), pos_integer()) ::
          ExRatatui.Widgets.Paragraph.t()
  def render(panel, status, width) do
    panel
    |> lines(status, width)
    |> Text.paragraph(%Style{fg: :yellow, modifiers: [:bold]})
  end
end
