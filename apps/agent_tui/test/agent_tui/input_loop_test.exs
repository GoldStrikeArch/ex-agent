defmodule AgentTui.InputLoopTest do
  use ExUnit.Case, async: true

  test "parses prompts and built-in commands" do
    assert AgentTui.InputLoop.parse_line("\n") == :ignore
    assert AgentTui.InputLoop.parse_line("hello\n") == {:prompt, "hello"}
    assert AgentTui.InputLoop.parse_line("/help\n") == {:command, :help}
    assert AgentTui.InputLoop.parse_line("/quit\n") == {:command, :quit}
    assert AgentTui.InputLoop.parse_line("/editor\n") == {:command, :editor}
  end

  test "rejects unknown slash commands before they reach the model" do
    assert AgentTui.InputLoop.parse_line("/model gpt\n") ==
             {:error, {:unknown_command, "/model"}}
  end
end
