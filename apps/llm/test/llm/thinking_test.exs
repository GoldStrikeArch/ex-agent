defmodule LLM.ThinkingTest do
  use ExUnit.Case, async: true

  alias LLM.Thinking

  test "normalizes user-facing thinking levels" do
    assert Thinking.normalize("HIGH") == {:ok, "high"}
    assert Thinking.normalize(:medium) == {:ok, "medium"}
    assert Thinking.normalize("min") == {:ok, "minimal"}
    assert Thinking.normalize("default") == {:ok, nil}
  end

  test "builds reasoning payloads from model opts" do
    assert Thinking.reasoning(reasoning_effort: "low") == {:ok, %{effort: "low"}}
    assert Thinking.reasoning(thinking_level: "high") == {:ok, %{effort: "high"}}
    assert Thinking.reasoning([]) == {:ok, nil}
  end

  test "rejects unknown thinking levels" do
    assert {:error, {:invalid_thinking_level, "huge", levels}} = Thinking.normalize("huge")
    assert "low" in levels
  end
end
