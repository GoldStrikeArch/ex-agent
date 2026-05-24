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
    assert_receive {:agent_core_event, {:user_message, "hello"}}
    assert_receive {:agent_core_event, {:assistant_message_started, ^message_id}}
    assert_receive {:agent_core_event, {:assistant_delta, ^message_id, "Mock response: hello"}}
    assert_receive {:agent_core_event, {:assistant_message_finished, ^message_id}}

    assert :ok = AgentCore.stop_session(session)
  end

  test "event log writes JSONL records" do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-core-event-log-#{System.unique_integer([:positive])}.jsonl"
      )

    assert {:ok, logger} = AgentCore.EventLog.start_link(path: path)

    AgentCore.EventBus.publish({:user_message, "logged"})

    assert_eventually(fn ->
      File.exists?(path) and File.read!(path) =~ ~S("event":"user_message")
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
