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

  test "round trips tool request and result messages" do
    events = [
      AgentCore.Event.message_finished(%{
        id: "message-tools",
        role: :assistant,
        content: "",
        tool_calls: [
          %{id: "tool-1", provider_id: "fc_1", name: "read_file", args: %{path: "mix.exs"}}
        ]
      }),
      AgentCore.Event.message_finished(%{
        id: "message-result",
        role: :tool,
        tool_call_id: "tool-1",
        name: "read_file",
        status: :ok,
        content: "contents",
        summary: "read mix.exs"
      })
    ]

    assert Enum.map(events, &round_trip/1) == events
  end

  defp round_trip(event) do
    event
    |> AgentCore.Event.to_record()
    |> JSON.encode!()
    |> JSON.decode!()
    |> AgentCore.Event.from_record()
    |> then(fn {:ok, decoded} -> decoded end)
  end
end
