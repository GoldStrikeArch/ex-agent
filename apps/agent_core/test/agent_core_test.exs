defmodule AgentCoreTest do
  use ExUnit.Case, async: false

  test "starts a session, handles a message, and emits events" do
    :ok = AgentCore.EventBus.subscribe()

    assert {:ok, session} = AgentCore.start_session()

    assert {:ok, %{message_id: message_id, content: "Mock response: hello"}} =
             AgentCore.send_message(session, "hello")

    assert {:ok, messages} = AgentCore.messages(session)

    assert [
             %{role: :user, content: "hello"},
             %{role: :assistant, content: "Mock response: hello"}
           ] = messages

    assert_receive {:agent_core_event, {:session_started, %{session_id: _session_id}}}
    assert_receive {:agent_core_event, {:agent_started, _session_id}}
    assert_receive {:agent_core_event, {:turn_started, turn_id}}
    assert_receive {:agent_core_event, {:message_started, _user_message_id, :user}}
    assert_receive {:agent_core_event, {:message_finished, %{role: :user, content: "hello"}}}
    assert_receive {:agent_core_event, {:message_started, ^message_id, :assistant}}
    assert_receive {:agent_core_event, {:message_delta, ^message_id, "Mock response: hello"}}

    assert_receive {:agent_core_event,
                    {:message_finished,
                     %{id: ^message_id, role: :assistant, content: "Mock response: hello"}}}

    assert_receive {:agent_core_event, {:turn_finished, ^turn_id, %{status: :ok}}}
    assert_receive {:agent_core_event, {:agent_finished, _session_id}}

    assert :ok = AgentCore.stop_session(session)
  end

  test "event log writes JSONL records" do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-core-event-log-#{System.unique_integer([:positive])}.jsonl"
      )

    assert {:ok, logger} = AgentCore.EventLog.start_link(path: path)

    AgentCore.EventBus.publish({:message_delta, "message-test", "logged"})

    assert_eventually(fn ->
      File.exists?(path) and File.read!(path) =~ ~S("event":"message_delta")
    end)

    GenServer.stop(logger)
    File.rm(path)
  end

  defp assert_eventually(fun) do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert fun.()
    end
  end
end
