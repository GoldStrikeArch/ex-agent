defmodule Tui.TerminalApp.RootTest do
  use ExUnit.Case, async: true

  alias Tui.TerminalApp.Prompt
  alias Tui.TerminalApp.Root
  alias ExRatatui.Event

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

  test "reports missing prompt callback instead of submitting" do
    state =
      Root.new(subscribe: false)
      |> Map.update!(:input, &Prompt.set_value(&1, "hello"))

    {state, []} = Root.reduce(:submit, state)
    assert state.notice == "submit failed: prompt callback is not configured"
  end

  defp key(code), do: %Event.Key{code: code, kind: "press"}
end
