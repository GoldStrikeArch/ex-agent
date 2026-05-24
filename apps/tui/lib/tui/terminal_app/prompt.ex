defmodule Tui.TerminalApp.Prompt do
  @moduledoc """
  Owns the ExRatatui textarea state for the chat prompt.
  """

  alias ExRatatui.Event
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Textarea

  defstruct max_visible_lines: 3,
            placeholder: "type a prompt, / for commands",
            state: nil,
            width: 80

  @type t :: %__MODULE__{
          max_visible_lines: pos_integer(),
          placeholder: String.t(),
          state: reference(),
          width: pos_integer()
        }

  @doc """
  Builds a focused chat prompt.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    state = ExRatatui.textarea_new()
    value = Keyword.get(opts, :value, "")
    :ok = ExRatatui.textarea_set_value(state, value)

    %__MODULE__{
      max_visible_lines: Keyword.get(opts, :max_visible_lines, 3),
      placeholder: Keyword.get(opts, :placeholder, "type a prompt, / for commands"),
      state: state,
      width: Keyword.get(opts, :width, 80)
    }
  end

  @doc """
  Returns the prompt text.
  """
  @spec value(t()) :: String.t()
  def value(%__MODULE__{state: state}), do: ExRatatui.textarea_get_value(state)

  @doc """
  Clears prompt text.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = input), do: set_value(input, "")

  @doc """
  Replaces prompt text.
  """
  @spec set_value(t(), String.t()) :: t()
  def set_value(%__MODULE__{state: state} = input, value) when is_binary(value) do
    :ok = ExRatatui.textarea_set_value(state, value)
    input
  end

  @doc """
  Updates the render width while preserving prompt text.
  """
  @spec resize(t(), pos_integer()) :: t()
  def resize(%__MODULE__{} = input, width) when is_integer(width) and width > 0 do
    %{input | width: width}
  end

  @doc """
  Applies a terminal input event to the prompt.
  """
  @spec handle_event(t(), Event.Key.t() | {:paste, String.t()}) :: t()
  def handle_event(%__MODULE__{} = input, {:paste, content}) when is_binary(content) do
    set_value(input, value(input) <> content)
  end

  def handle_event(%__MODULE__{state: state} = input, %Event.Key{
        code: code,
        modifiers: modifiers,
        kind: "press"
      })
      when is_binary(code) do
    :ok = ExRatatui.textarea_handle_key(state, code, modifiers)
    input
  end

  def handle_event(%__MODULE__{} = input, _event) do
    input
  end

  @doc """
  Renders the prompt.
  """
  @spec render(t()) :: Textarea.t()
  def render(%__MODULE__{} = input) do
    %Textarea{
      state: input.state,
      placeholder: input.placeholder,
      placeholder_style: %Style{fg: :dark_gray},
      cursor_style: %Style{modifiers: [:reversed]},
      cursor_line_style: %Style{bg: :reset},
      style: %Style{fg: :white}
    }
  end
end
