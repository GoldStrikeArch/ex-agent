defmodule Tui.TerminalApp.TranscriptTest do
  use ExUnit.Case, async: true

  alias Tui.TerminalApp.Transcript

  test "stores assistant streams as a single block updated in place" do
    transcript =
      Transcript.new()
      |> Transcript.append_event({:message_started, "message-1", :assistant})
      |> Transcript.append_event({:message_delta, "message-1", "hello"})
      |> Transcript.append_event({:message_delta, "message-1", ", world"})

    assert [%{id: "message-1", kind: :assistant, status: :streaming, body: ["hello, world"]}] =
             Transcript.blocks(transcript)

    transcript =
      Transcript.append_event(
        transcript,
        {:message_finished, %{id: "message-1", role: :assistant}}
      )

    assert [%{id: "message-1", kind: :assistant, status: :done, body: ["hello, world"]}] =
             Transcript.blocks(transcript)
  end

  test "tracks tool output bytes without dumping output chunks into the transcript" do
    transcript =
      Transcript.new()
      |> Transcript.append_event({:tool_started, "tool-1", "read_file", %{"path" => "README.md"}})
      |> Transcript.append_event({:tool_output, "tool-1", "abc"})
      |> Transcript.append_event({:tool_output, "tool-1", "defg"})

    assert [%{kind: :tool, status: :streaming, body: body}] = Transcript.blocks(transcript)
    assert "output 7 B" in body
    refute Enum.any?(body, &String.contains?(&1, "abcdefg"))

    transcript = Transcript.append_event(transcript, {:tool_finished, "tool-1", :error, "failed"})

    assert [%{kind: :tool, status: :error, body: body}] = Transcript.blocks(transcript)
    assert "summary failed" in body
  end

  test "renders permissions and edit previews as dedicated block kinds" do
    transcript =
      Transcript.new()
      |> Transcript.append_event({:permission_requested, "request-1", "shell: mix test"})
      |> Transcript.append_event({:permission_resolved, "request-1", "allow"})
      |> Transcript.append_event({:edit_preview, "edit-1", "lib/example.ex", "-old\n+new"})

    assert [
             %{kind: :permission, status: :done, body: ["\"allow\""]},
             %{kind: :edit, title: "edit preview lib/example.ex", body: ["-old\n+new"]}
           ] = Transcript.blocks(transcript)

    rendered = Enum.join(Transcript.visible_lines(transcript, 80, 10), "\n")
    assert rendered =~ "[done] permission resolved request-1"
    assert rendered =~ "[edit] edit preview lib/example.ex"
  end
end
