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

  test "delegates model command through command handler" do
    parent = self()

    state =
      Root.new(subscribe: false)
      |> Map.put(:command_handler, fn command_id, context ->
        send(parent, {:handled_command, command_id, context})
        :ok
      end)
      |> Map.update!(:input, &Prompt.set_value(&1, "/model"))

    {state, []} = Root.reduce(:submit, state)

    assert Prompt.value(state.input) == ""
    assert MapSet.size(state.pending_prompts) == 1
    assert_receive {:handled_command, :model, %{prompt: "/model"}}
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

  defp key(code), do: %Event.Key{code: code, kind: "press"}
end
