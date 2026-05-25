defmodule Tui.TerminalApp.CommandMenuTest do
  use ExUnit.Case, async: true

  alias Tui.TerminalApp.CommandMenu

  test "filters slash commands by prefix" do
    assert CommandMenu.visible?("/")
    assert [%{id: :status}] = CommandMenu.filtered("/st")
    assert [] = CommandMenu.filtered("/missing")
  end

  test "wraps selection movement" do
    assert CommandMenu.move(0, -1, "/") == 4
    assert CommandMenu.move(4, 1, "/") == 0
  end

  test "renders selected menu line" do
    assert [line | _rest] = CommandMenu.lines("/", 0, 80)
    assert line =~ "> /help"
  end

  test "includes model setup command" do
    assert Enum.any?(CommandMenu.commands(), &match?(%{id: :model, label: "/model"}, &1))
  end
end
