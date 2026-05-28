defmodule Tui.ReplayTest do
  use ExUnit.Case, async: true

  test "renders JSONL event logs without starting a session" do
    path =
      Path.join(System.tmp_dir!(), "agent-tui-replay-#{System.unique_integer([:positive])}.jsonl")

    records = [
      record("session_started", [%{"session_id" => "session-replay"}]),
      record("message_finished", [
        %{"id" => "message-user", "role" => "user", "content" => "hello"}
      ]),
      record("message_started", ["message-assistant", "assistant"]),
      record("model_request", [
        "model-1",
        %{"message_count" => 1, "model_client" => "Core.ModelClient.Mock"}
      ]),
      record("message_delta", ["message-assistant", "hi"]),
      record("model_response", [
        "model-1",
        %{"status" => "ok", "response" => %{"content" => %{"text" => "hi"}}}
      ]),
      record("message_finished", [
        %{"id" => "message-assistant", "role" => "assistant", "content" => "hi"}
      ])
    ]

    lines =
      records
      |> Enum.map(&JSON.encode!/1)
      |> Enum.join("\n")

    File.write!(path, lines <> "\n")

    {:ok, io} = StringIO.open("")
    assert :ok = Tui.Replay.render_file(path, io: io)
    {_input, output} = StringIO.contents(io)

    assert output == """
           session started session-replay
           user> hello
           assistant> hi
           """

    File.rm(path)
  end

  defp record(event, payload) do
    %{"event" => event, "payload" => payload}
  end
end
