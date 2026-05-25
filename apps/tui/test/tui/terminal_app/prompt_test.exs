defmodule Tui.TerminalApp.PromptTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias Tui.TerminalApp.Prompt

  test "handles character input and backspace" do
    input =
      Prompt.new()
      |> Prompt.handle_event(key("h"))
      |> Prompt.handle_event(key("i"))
      |> Prompt.handle_event(key("backspace"))

    assert Prompt.value(input) == "h"
  end

  test "handles paste input" do
    input =
      Prompt.new()
      |> Prompt.handle_event({:paste, "hello\nworld"})

    assert Prompt.value(input) == "hello\nworld"
  end

  test "inserts a newline at the cursor" do
    input =
      Prompt.new()
      |> Prompt.handle_event(key("h"))
      |> Prompt.handle_event(key("i"))
      |> Prompt.insert_newline()
      |> Prompt.handle_event(key("a"))

    assert Prompt.value(input) == "hi\na"
    assert Prompt.line_count(input) == 2
    assert {1, 1} = Prompt.cursor(input)
  end

  defp key(code), do: %Event.Key{code: code, kind: "press"}
end
