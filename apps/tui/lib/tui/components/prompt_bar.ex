defmodule Tui.Components.PromptBar do
  @moduledoc """
  Renders the prompt prefix and textarea widget.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph
  alias Tui.TerminalApp.Prompt

  @doc """
  Renders prompt widgets for the supplied rectangle.
  """
  @spec render(Prompt.t(), Rect.t()) :: [{ExRatatui.widget(), Rect.t()}]
  def render(input, %{width: width, height: height} = rect) when width > 2 and height > 0 do
    prefix_rect = %{rect | width: 2}
    input_rect = %{rect | x: rect.x + 2, width: width - 2}

    [
      {%Paragraph{text: "> ", style: %Style{fg: :green, modifiers: [:bold]}}, prefix_rect},
      {Prompt.render(input), input_rect}
    ]
  end

  def render(_input, _rect), do: []
end
