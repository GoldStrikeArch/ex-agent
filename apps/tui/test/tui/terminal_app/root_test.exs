defmodule Tui.TerminalApp.RootTest do
  use ExUnit.Case, async: true

  alias Tui.TerminalApp.Prompt
  alias Tui.TerminalApp.Root
  alias ExRatatui.Event
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.Scrollbar

  test "opens and executes the status command from slash input" do
    state = Root.new(subscribe: false)

    {:msg, msg} = Root.event_to_msg(key("/"), state)
    {state, []} = Root.reduce(msg, state)
    assert Prompt.value(state.input) == "/"

    {:msg, msg} = Root.event_to_msg(key("s"), state)
    {state, []} = Root.reduce(msg, state)
    {:msg, msg} = Root.event_to_msg(key("t"), state)
    {state, []} = Root.reduce(msg, state)

    {state, []} = Root.reduce(:submit, state)
    assert state.panel == :status
    assert Prompt.value(state.input) == ""
  end

  test "captures agent events into status and transcript state" do
    state = Root.new(subscribe: false)
    {state, []} = Root.reduce({:agent_event, {:session_started, %{session_id: "s1"}}}, state)

    assert state.status.session_id == "s1"

    lines = Tui.TerminalApp.Transcript.visible_lines(state.transcript, 80, 4)
    assert lines == ["session started s1"]
  end

  test "high-frequency streaming events signal :skip_render so paints coalesce" do
    state = Root.new(subscribe: false)

    {_state, actions} = Root.reduce({:agent_event, {:message_delta, "m1", "tok"}}, state)
    assert actions == [:skip_render]

    {_state, actions} = Root.reduce({:agent_event, {:tool_output, "t1", "chunk"}}, state)
    assert actions == [:skip_render]

    # Lower-frequency events still render immediately.
    {_state, actions} =
      Root.reduce({:agent_event, {:message_started, "m1", :assistant}}, state)

    assert actions == []
  end

  test "reports missing prompt callback instead of submitting" do
    state =
      Root.new(subscribe: false)
      |> Map.update!(:input, &Prompt.set_value(&1, "hello"))

    {state, []} = Root.reduce(:submit, state)
    assert state.notice == "submit failed: prompt callback is not configured"
  end

  test "delegates model command through command handler" do
    parent = self()

    state =
      Root.new(subscribe: false)
      |> Map.put(:command_handler, fn command_id, context ->
        send(parent, {:handled_command, command_id, context})
        :ok
      end)
      |> Map.update!(:input, &Prompt.set_value(&1, "/model high"))

    {state, []} = Root.reduce(:submit, state)

    assert Prompt.value(state.input) == ""
    assert MapSet.size(state.pending_prompts) == 1
    assert_receive {:handled_command, :model, %{prompt: "/model high"}}
    assert_receive {:command_result, _ref, :ok}
  end

  test "reports prompt callback exits without crashing the task" do
    state =
      Root.new(subscribe: false)
      |> Map.put(:submit_prompt, fn _prompt -> exit(:timeout) end)
      |> Map.update!(:input, &Prompt.set_value(&1, "hello"))

    {state, []} = Root.reduce(:submit, state)

    assert MapSet.size(state.pending_prompts) == 1
    assert_receive {:prompt_result, prompt_ref, {:error, {:callback_exit, :timeout}}}

    {state, []} =
      Root.reduce({:prompt_result, prompt_ref, {:error, {:callback_exit, :timeout}}}, state)

    assert state.notice == "prompt failed: {:callback_exit, :timeout}"
    assert MapSet.size(state.pending_prompts) == 0
  end

  test "reports command callback exceptions without crashing the task" do
    state =
      Root.new(subscribe: false)
      |> Map.put(:command_handler, fn _command_id, _context -> raise "boom" end)
      |> Map.update!(:input, &Prompt.set_value(&1, "/model"))

    {state, []} = Root.reduce(:submit, state)

    assert MapSet.size(state.pending_prompts) == 1

    assert_receive {:command_result, command_ref,
                    {:error, {:callback_exception, RuntimeError, "boom"}}}

    {state, []} =
      Root.reduce(
        {:command_result, command_ref, {:error, {:callback_exception, RuntimeError, "boom"}}},
        state
      )

    assert state.notice == "command failed: {:callback_exception, RuntimeError, \"boom\"}"
    assert MapSet.size(state.pending_prompts) == 0
  end

  test "appends app notices to transcript" do
    state = Root.new(subscribe: false)

    {state, []} = Root.reduce({:append_notice, "model configured"}, state)

    assert state.notice == "model configured"

    assert Tui.TerminalApp.Transcript.visible_lines(state.transcript, 80, 4) == [
             "model configured"
           ]
  end

  test "plain enter submits but modified enter inserts a newline" do
    state = Root.new(subscribe: false)

    assert {:msg, :submit} = Root.event_to_msg(key("enter"), state)
    assert {:msg, :insert_newline} = Root.event_to_msg(key("enter", ["alt"]), state)
    assert {:msg, :insert_newline} = Root.event_to_msg(key("enter", ["shift"]), state)
    assert {:msg, :insert_newline} = Root.event_to_msg(key("j", ["ctrl"]), state)
  end

  test "inserts a newline into the prompt without submitting" do
    state = Root.new(subscribe: false)

    {state, []} = Root.reduce({:input_event, key("a")}, state)
    {state, []} = Root.reduce(:insert_newline, state)
    {state, []} = Root.reduce({:input_event, key("b")}, state)

    assert Prompt.value(state.input) == "a\nb"
  end

  test "navigates submitted prompt history with up and down" do
    state =
      Root.new(subscribe: false)
      |> Map.put(:submit_prompt, fn _prompt -> :ok end)

    state = submit_text(state, "first")
    state = submit_text(state, "second")

    # cursor sits on the (empty) first line, so up recalls history
    {state, []} = Root.reduce({:history_prev, key("up")}, state)
    assert Prompt.value(state.input) == "second"

    {state, []} = Root.reduce({:history_prev, key("up")}, state)
    assert Prompt.value(state.input) == "first"

    {state, []} = Root.reduce({:history_next, key("down")}, state)
    assert Prompt.value(state.input) == "second"

    # stepping past the newest entry restores the in-progress draft
    {state, []} = Root.reduce({:history_next, key("down")}, state)
    assert Prompt.value(state.input) == ""
  end

  test "scrolls the transcript and re-follows at the bottom" do
    state = Root.new(subscribe: false, width: 80, height: 24)

    state =
      Enum.reduce(1..40, state, fn n, acc ->
        {acc, []} = Root.reduce({:agent_event, {:user_message, "msg #{n}"}}, acc)
        acc
      end)

    {scrolled, []} = Root.reduce({:scroll, :page_up, 5}, state)
    refute scrolled.transcript.follow?

    {bottom, []} = Root.reduce({:scroll, :bottom, 5}, scrolled)
    assert bottom.transcript.follow?
  end

  test "ctrl+l clears the transcript viewport" do
    state = Root.new(subscribe: false)
    {state, []} = Root.reduce({:agent_event, {:user_message, "hello"}}, state)

    assert {:msg, :clear_transcript} = Root.event_to_msg(key("l", ["ctrl"]), state)

    {state, []} = Root.reduce(:clear_transcript, state)
    assert Tui.TerminalApp.Transcript.visible_lines(state.transcript, 80, 4) == []
  end

  test "maps mouse wheel events to line scrolling" do
    state = Root.new(subscribe: false)

    assert {:msg, {:scroll, {:lines, -3}, _height}} =
             Root.event_to_msg(%Event.Mouse{kind: "scroll_up"}, state)

    assert {:msg, {:scroll, {:lines, 3}, _height}} =
             Root.event_to_msg(%Event.Mouse{kind: "scroll_down"}, state)
  end

  test "places the scrollbar thumb at the bottom while following and at the top when scrolled up" do
    width = 100
    height = 40

    big = Enum.map_join(1..60, "\n", fn n -> "line #{n}" end)

    state =
      [
        {:assistant_message_started, "m1"},
        {:assistant_delta, "m1", big},
        {:assistant_message_finished, "m1"}
      ]
      |> Enum.reduce(Root.new(subscribe: false, width: width, height: height), fn event, acc ->
        {acc, _actions} = Root.reduce({:agent_event, event}, acc)
        acc
      end)

    # following: the thumb is pinned to the bottom (position == content_length)
    assert state.transcript.follow?
    following = scrollbar(state, width, height)
    assert following.position == following.content_length
    assert following.content_length > 0
    # the scrollbar is driven by the scrollable range, not the total line count
    refute following.viewport_content_length

    # scrolled to the top: the thumb is at the top (position 0)
    {top, []} = Root.reduce({:scroll, :top, transcript_height(state)}, state)
    assert scrollbar(top, width, height).position == 0
  end

  defp scrollbar(state, width, height) do
    state
    |> Root.scene(%Frame{width: width, height: height})
    |> Enum.find_value(fn
      {%Scrollbar{} = bar, _rect} -> bar
      _ -> nil
    end)
  end

  defp transcript_height(state) do
    {:msg, {:scroll, _dir, height}} =
      Root.event_to_msg(%Event.Key{code: "page_up", kind: "press"}, state)

    height
  end

  defp submit_text(state, text) do
    state = Map.update!(state, :input, &Prompt.set_value(&1, text))
    {state, []} = Root.reduce(:submit, state)
    state
  end

  defp key(code), do: %Event.Key{code: code, kind: "press"}
  defp key(code, modifiers), do: %Event.Key{code: code, kind: "press", modifiers: modifiers}
end
