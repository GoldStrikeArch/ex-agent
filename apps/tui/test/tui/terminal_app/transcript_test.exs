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

  test "follows the bottom by default and anchors when scrolled up" do
    transcript =
      Enum.reduce(1..10, Transcript.new(), fn n, acc ->
        Transcript.append_event(acc, {:user_message, "line #{n}"})
      end)

    assert Transcript.visible_lines(transcript, 80, 3) == [
             "user> line 8",
             "user> line 9",
             "user> line 10"
           ]

    scrolled = Transcript.scroll(transcript, :page_up, 80, 3)
    refute scrolled.follow?

    assert Transcript.visible_lines(scrolled, 80, 3) == [
             "user> line 5",
             "user> line 6",
             "user> line 7"
           ]

    # appends while scrolled up do not move the anchored view
    scrolled = Transcript.append_event(scrolled, {:user_message, "line 11"})

    assert Transcript.visible_lines(scrolled, 80, 3) == [
             "user> line 5",
             "user> line 6",
             "user> line 7"
           ]

    # jumping to the top, then back to the bottom re-follows
    top = Transcript.scroll(scrolled, :top, 80, 3)

    assert Transcript.visible_lines(top, 80, 3) == [
             "user> line 1",
             "user> line 2",
             "user> line 3"
           ]

    bottom = Transcript.scroll(top, :bottom, 80, 3)
    assert bottom.follow?
    assert List.last(Transcript.visible_lines(bottom, 80, 3)) == "user> line 11"
  end

  test "keeps the anchored view fixed when older blocks evict off the top" do
    transcript =
      Enum.reduce(1..5, Transcript.new(max_blocks: 5), fn n, acc ->
        Transcript.append_event(acc, {:user_message, "line #{n}"})
      end)

    # scroll up one line: viewport now starts at line 3
    scrolled = Transcript.scroll(transcript, {:lines, -1}, 80, 2)
    refute scrolled.follow?
    assert Transcript.visible_lines(scrolled, 80, 2) == ["user> line 3", "user> line 4"]

    # a new block evicts "line 1"; an absolute-index anchor would drift, the
    # block-identity anchor keeps line 3 pinned to the top
    scrolled = Transcript.append_event(scrolled, {:user_message, "line 6"})
    assert Transcript.visible_lines(scrolled, 80, 2) == ["user> line 3", "user> line 4"]
  end

  test "scrolls by individual lines" do
    transcript =
      Enum.reduce(1..6, Transcript.new(), fn n, acc ->
        Transcript.append_event(acc, {:user_message, "line #{n}"})
      end)

    up_two =
      transcript
      |> Transcript.scroll({:lines, -1}, 80, 2)
      |> Transcript.scroll({:lines, -1}, 80, 2)

    assert Transcript.visible_lines(up_two, 80, 2) == ["user> line 3", "user> line 4"]

    back_down = Transcript.scroll(up_two, {:lines, 1}, 80, 2)
    assert Transcript.visible_lines(back_down, 80, 2) == ["user> line 4", "user> line 5"]
  end

  test "reports viewport metrics for the scroll indicator" do
    transcript =
      Enum.reduce(1..10, Transcript.new(), fn n, acc ->
        Transcript.append_event(acc, {:user_message, "line #{n}"})
      end)

    assert %{content_length: 10, position: 7, viewport: 3} =
             Transcript.viewport_metrics(transcript, 80, 3)

    scrolled = Transcript.scroll(transcript, :top, 80, 3)

    assert %{content_length: 10, position: 0, viewport: 3} =
             Transcript.viewport_metrics(scrolled, 80, 3)
  end

  test "content_width reserves one column for the scrollbar gutter" do
    assert Transcript.content_width(80) == 79
    assert Transcript.content_width(1) == 1
  end

  test "tags visible lines with a style category per block kind" do
    transcript =
      Transcript.new()
      |> Transcript.append_event({:user_message, "hi"})
      |> Transcript.append_event({:message_started, "m1", :assistant})
      |> Transcript.append_event({:message_delta, "m1", "answer"})
      |> Transcript.append_event({:tool_started, "call-1", "read_file", %{path: "mix.exs"}})
      |> Transcript.append_event({:error, :model, "boom"})

    tagged = Transcript.visible_styled_lines(transcript, 80, 20)

    assert {:user, "user> hi"} in tagged
    assert {:assistant, "  answer"} in tagged
    assert Enum.any?(tagged, &match?({:tool_header, _}, &1))
    assert Enum.any?(tagged, &match?({:error, _}, &1))

    # visible_lines keeps returning plain strings for the same content
    assert "user> hi" in Transcript.visible_lines(transcript, 80, 20)
  end
end
