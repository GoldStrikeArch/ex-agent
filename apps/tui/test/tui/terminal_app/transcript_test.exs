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

  test "renders tool blocks as a single line and never dumps tool output" do
    transcript =
      Transcript.new()
      |> Transcript.append_event({:tool_started, "tool-1", "read_file", %{"path" => "README.md"}})
      |> Transcript.append_event({:tool_output, "tool-1", "abc"})
      |> Transcript.append_event({:tool_output, "tool-1", "defg"})

    assert [%{kind: :tool, status: :streaming, title: title, body: []}] =
             Transcript.blocks(transcript)

    assert title == "read_file README.md"

    transcript = Transcript.append_event(transcript, {:tool_finished, "tool-1", :error, "failed"})

    assert [%{kind: :tool, status: :error, title: title, body: []}] =
             Transcript.blocks(transcript)

    assert title == "read_file README.md · failed"

    rendered = Enum.join(Transcript.visible_lines(transcript, 80, 10), "\n")
    refute rendered =~ "abcdefg"
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

  test "colors diff lines by their prefix" do
    diff = "@@ -1,2 +1,2 @@\n context\n-removed\n+added"

    tagged =
      Transcript.new()
      |> Transcript.append_event({:edit_preview, "edit-1", "lib/a.ex", diff})
      |> Transcript.visible_styled_lines(80, 20)

    assert {:diff_hunk, "  @@ -1,2 +1,2 @@"} in tagged
    assert {:diff_context, "   context"} in tagged
    assert {:diff_del, "  -removed"} in tagged
    assert {:diff_add, "  +added"} in tagged
  end

  test "renders a finished tool as `name target · duration` from injected timestamps" do
    transcript =
      Transcript.new()
      |> Transcript.append_event(
        {:tool_started, "t1", "read_file", %{"path" => "README.md"}},
        1_000
      )
      |> Transcript.append_event({:tool_finished, "t1", :ok, "read 10 lines"}, 1_050)

    assert [%{kind: :tool, status: :done, title: "read_file README.md · 50ms", body: []}] =
             Transcript.blocks(transcript)
  end

  test "omits the duration suffix when no timestamp is supplied" do
    transcript =
      Transcript.new()
      |> Transcript.append_event({:tool_started, "t1", "read_file", %{"path" => "README.md"}})
      |> Transcript.append_event({:tool_finished, "t1", :ok, "done"})

    assert [%{kind: :tool, title: "read_file README.md", body: []}] =
             Transcript.blocks(transcript)
  end

  test "separates blocks of different kinds with a blank line" do
    tagged =
      Transcript.new()
      |> Transcript.append_event({:user_message, "hi"})
      |> Transcript.append_event({:message_started, "m1", :assistant})
      |> Transcript.append_event({:message_delta, "m1", "yo"})
      |> Transcript.visible_styled_lines(80, 20)

    assert {:blank, ""} in tagged

    # consecutive same-kind blocks are not separated
    same_kind =
      Transcript.new()
      |> Transcript.append_event({:user_message, "one"})
      |> Transcript.append_event({:user_message, "two"})
      |> Transcript.visible_styled_lines(80, 20)

    refute {:blank, ""} in same_kind
  end

  test "display_width counts wide and zero-width characters" do
    assert Transcript.display_width("abc") == 3
    # CJK characters occupy two columns each
    assert Transcript.display_width("你好") == 4
    # a combining mark adds no width on top of its base letter
    assert Transcript.display_width("é") == 1
  end

  test "wraps on word boundaries instead of mid-word" do
    lines =
      Transcript.new()
      |> Transcript.append_event({:user_message, "alpha beta gamma delta"})
      # content width 12 -> "user> alpha", then the rest wraps at spaces
      |> Transcript.visible_lines(12, 20)

    assert "user> alpha" in lines
    refute Enum.any?(lines, &String.contains?(&1, "alp\nha"))
    assert Enum.all?(lines, &(Transcript.display_width(&1) <= 12))
  end

  test "wraps wide characters by display width, not grapheme count" do
    lines =
      Transcript.new()
      |> Transcript.append_event({:user_message, "你好世界你好世界"})
      |> Transcript.visible_lines(10, 20)

    # every wrapped line stays within the 10-column viewport
    assert Enum.all?(lines, &(Transcript.display_width(&1) <= 10))
    # and a naive grapheme-chunk would have overflowed (8 CJK = 16 columns)
    assert Transcript.display_width(Enum.join(lines)) >= 16
  end

  test "prefixes a running tool header with the spinner glyph, finished tools without" do
    transcript =
      Transcript.new()
      |> Transcript.append_event({:tool_started, "t1", "read_file", %{"path" => "mix.exs"}})

    assert running =
             transcript
             |> Transcript.visible_styled_lines(80, 20, "*")
             |> Enum.find_value(fn {:tool_header, text} -> text end)

    assert running == "* read_file mix.exs"
    assert Transcript.running?(transcript)

    finished = Transcript.append_event(transcript, {:tool_finished, "t1", :ok, "ok"})

    headers =
      finished
      |> Transcript.visible_styled_lines(80, 20, "*")
      |> Enum.filter(&match?({:tool_header, _}, &1))

    assert Enum.any?(headers, fn {_tag, text} -> text == "[done] read_file mix.exs" end)
    refute Transcript.running?(finished)
  end
end
