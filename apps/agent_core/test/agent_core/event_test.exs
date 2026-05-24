defmodule AgentCore.EventTest do
  use ExUnit.Case, async: true

  test "constructs the public tuple events" do
    assert AgentCore.Event.session_started(%{session_id: "session-1"}) ==
             {:session_started, %{session_id: "session-1"}}

    assert AgentCore.Event.tool_started("tool-1", "read_file", %{path: "mix.exs"}) ==
             {:tool_started, "tool-1", "read_file", %{path: "mix.exs"}}
  end

  test "round trips through JSONL records" do
    event =
      AgentCore.Event.message_finished(%{
        id: "message-1",
        role: :assistant,
        content: "done"
      })

    record = AgentCore.Event.to_record(event)

    assert {:ok, decoded} =
             record
             |> JSON.encode!()
             |> JSON.decode!()
             |> AgentCore.Event.from_record()

    assert decoded == event
  end
end
