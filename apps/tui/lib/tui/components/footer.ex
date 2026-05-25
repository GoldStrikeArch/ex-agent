defmodule Tui.Components.Footer do
  @moduledoc """
  Renders the bottom help, notice, and running state line.
  """

  alias ExRatatui.Style
  alias Tui.Components.Text
  alias Tui.TerminalApp.State

  @doc """
  Returns the footer line for the current state.
  """
  @spec line(State.t()) :: String.t()
  def line(%{notice: notice}) when is_binary(notice), do: notice

  def line(%{pending_prompts: pending_prompts}) do
    if MapSet.size(pending_prompts) > 0 do
      "running..."
    else
      "Enter send | /status | /help | Ctrl+C quit"
    end
  end

  @doc """
  Renders the footer line as a paragraph.
  """
  @spec render(State.t(), pos_integer()) :: ExRatatui.Widgets.Paragraph.t()
  def render(state, width) do
    state
    |> line()
    |> Text.fit_line(width)
    |> List.wrap()
    |> Text.paragraph(%Style{fg: :dark_gray})
  end
end
