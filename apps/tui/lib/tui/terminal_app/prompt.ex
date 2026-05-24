defmodule Tui.TerminalApp.Prompt do
  @moduledoc """
  Thin wrapper around TermUI's text input widget.
  """

  alias TermUI.Event
  alias TermUI.Widgets.TextInput

  @type t :: map()

  @doc """
  Builds a focused chat prompt.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    props =
      TextInput.new(
        value: Keyword.get(opts, :value, ""),
        placeholder: Keyword.get(opts, :placeholder, "type a prompt, / for commands"),
        width: Keyword.get(opts, :width, 80),
        multiline: true,
        max_visible_lines: Keyword.get(opts, :max_visible_lines, 3),
        enter_submits: true
      )

    {:ok, input} = TextInput.init(props)
    TextInput.set_focused(input, true)
  end

  @doc """
  Returns the prompt text.
  """
  @spec value(t()) :: String.t()
  def value(input), do: TextInput.get_value(input)

  @doc """
  Clears prompt text.
  """
  @spec clear(t()) :: t()
  def clear(input), do: TextInput.clear(input)

  @doc """
  Replaces prompt text.
  """
  @spec set_value(t(), String.t()) :: t()
  def set_value(input, value) when is_binary(value) do
    TextInput.set_value(input, value)
  end

  @doc """
  Updates the render width while preserving prompt text.
  """
  @spec resize(t(), pos_integer()) :: t()
  def resize(input, width) when is_integer(width) and width > 0 do
    props =
      TextInput.new(
        value: value(input),
        placeholder: Map.get(input, :placeholder, "type a prompt, / for commands"),
        width: width,
        multiline: Map.get(input, :multiline, true),
        max_visible_lines: Map.get(input, :max_visible_lines, 3),
        enter_submits: Map.get(input, :enter_submits, true)
      )

    {:ok, input} = TextInput.update(props, input)
    TextInput.set_focused(input, true)
  end

  @doc """
  Applies a terminal input event to the prompt.
  """
  @spec handle_event(t(), TermUI.Event.t()) :: t()
  def handle_event(input, %Event.Paste{content: content}) do
    set_value(input, value(input) <> content)
  end

  def handle_event(input, event) do
    {:ok, input} = TextInput.handle_event(event, input)
    TextInput.set_focused(input, true)
  end

  @doc """
  Renders the prompt.
  """
  @spec render(t()) :: TermUI.Component.RenderNode.t()
  def render(input), do: TextInput.render(input, %{})
end
