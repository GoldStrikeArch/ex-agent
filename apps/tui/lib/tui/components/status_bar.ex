defmodule Tui.Components.StatusBar do
  @moduledoc """
  Renders the compact agent status line.
  """

  alias ExRatatui.Style
  alias Tui.Components.Text
  alias Tui.TerminalApp.Status

  @doc """
  Renders the status snapshot as a one-line paragraph.
  """
  @spec render(Status.t(), pos_integer()) :: ExRatatui.Widgets.Paragraph.t()
  def render(status, width) do
    status
    |> Status.summary_line()
    |> Text.fit_line(width)
    |> List.wrap()
    |> Text.paragraph(%Style{fg: :dark_gray})
  end
end
