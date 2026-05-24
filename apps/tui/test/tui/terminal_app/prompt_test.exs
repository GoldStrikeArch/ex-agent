defmodule Tui.TerminalApp.PromptTest do
  use ExUnit.Case, async: true

  alias Tui.TerminalApp.Prompt
  alias TermUI.Event

  test "handles character input and backspace" do
    input =
      Prompt.new()
      |> Prompt.handle_event(Event.key("h", char: "h"))
      |> Prompt.handle_event(Event.key("i", char: "i"))
      |> Prompt.handle_event(Event.key(:backspace))

    assert Prompt.value(input) == "h"
  end

  test "handles paste input" do
    input =
      Prompt.new()
      |> Prompt.handle_event(Event.paste("hello\nworld"))

    assert Prompt.value(input) == "hello\nworld"
  end
end
