defmodule AgentTui.TerminalApp.RootTest do
  use ExUnit.Case, async: true

  alias AgentTui.TerminalApp.Prompt
  alias AgentTui.TerminalApp.Root
  alias TermUI.Event

  test "opens and executes the status command from slash input" do
    state = Root.init(subscribe: false)

    {:msg, msg} = Root.event_to_msg(Event.key("/", char: "/"), state)
    {state, []} = Root.update(msg, state)
    assert Prompt.value(state.input) == "/"

    {:msg, msg} = Root.event_to_msg(Event.key("s", char: "s"), state)
    {state, []} = Root.update(msg, state)
    {:msg, msg} = Root.event_to_msg(Event.key("t", char: "t"), state)
    {state, []} = Root.update(msg, state)

    {state, []} = Root.update(:submit, state)
    assert state.panel == :status
    assert Prompt.value(state.input) == ""
  end

  test "captures core events into status and transcript state" do
    state = Root.init(subscribe: false)
    {state, []} = Root.update({:agent_core_event, {:session_started, %{session_id: "s1"}}}, state)

    assert state.status.session_id == "s1"

    lines = AgentTui.TerminalApp.Transcript.visible_lines(state.transcript, 80, 4)
    assert lines == ["session started s1"]
  end

  test "reports missing session instead of submitting" do
    state =
      Root.init(subscribe: false)
      |> Map.update!(:input, &Prompt.set_value(&1, "hello"))

    {state, []} = Root.update(:submit, state)
    assert state.notice == "submit failed: session is not running"
  end
end
