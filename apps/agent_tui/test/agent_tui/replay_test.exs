defmodule AgentTui.ReplayTest do
  use ExUnit.Case, async: true

  test "renders JSONL event logs without starting a session" do
    path =
      Path.join(System.tmp_dir!(), "agent-tui-replay-#{System.unique_integer([:positive])}.jsonl")

    events = [
      AgentCore.Event.session_started(%{session_id: "session-replay"}),
      AgentCore.Event.message_finished(%{id: "message-user", role: :user, content: "hello"}),
      AgentCore.Event.message_started("message-assistant", :assistant),
      AgentCore.Event.message_delta("message-assistant", "hi"),
      AgentCore.Event.message_finished(%{
        id: "message-assistant",
        role: :assistant,
        content: "hi"
      })
    ]

    lines =
      events
      |> Enum.map(&AgentCore.Event.to_record/1)
      |> Enum.map(&JSON.encode!/1)
      |> Enum.join("\n")

    File.write!(path, lines <> "\n")

    {:ok, io} = StringIO.open("")
    assert :ok = AgentTui.Replay.render_file(path, io: io)
    {_input, output} = StringIO.contents(io)

    assert output == """
           session started session-replay
           user> hello
           assistant> hi
           """

    File.rm(path)
  end
end
