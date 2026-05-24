defmodule CoreTest do
  use ExUnit.Case, async: false

  test "starts a session, handles a message, and emits events" do
    :ok = Core.EventBus.subscribe()

    assert {:ok, session} = Core.start_session()

    assert {:ok, %{message_id: message_id, content: "Mock response: hello"}} =
             Core.send_message(session, "hello")

    assert {:ok, messages} = Core.messages(session)

    assert [
             %{role: :user, content: "hello"},
             %{role: :assistant, content: "Mock response: hello"}
           ] = messages

    assert_receive {:core_event, {:session_started, %{session_id: _session_id}}}
    assert_receive {:core_event, {:agent_started, _session_id}}
    assert_receive {:core_event, {:turn_started, turn_id}}
    assert_receive {:core_event, {:message_started, _user_message_id, :user}}
    assert_receive {:core_event, {:message_finished, %{role: :user, content: "hello"}}}
    assert_receive {:core_event, {:message_started, ^message_id, :assistant}}
    assert_receive {:core_event, {:message_delta, ^message_id, "Mock response: hello"}}

    assert_receive {:core_event,
                    {:message_finished,
                     %{id: ^message_id, role: :assistant, content: "Mock response: hello"}}}

    assert_receive {:core_event, {:turn_finished, ^turn_id, %{status: :ok}}}
    assert_receive {:core_event, {:agent_finished, _session_id}}

    assert :ok = Core.stop_session(session)
  end

  test "runs scripted model tool calls and records tool result messages" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "agent-core-session-tools-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "mix.exs"), "defmodule Sample do\nend\n")

    on_exit(fn -> File.rm_rf(workspace) end)

    :ok = Core.EventBus.subscribe()

    script = [
      %{
        tool_calls: [
          %{id: "tool-read", name: "read_file", args: %{"path" => "mix.exs"}}
        ]
      }
    ]

    assert {:ok, session} =
             Core.start_session(workspace_root: workspace, model_opts: [script: script])

    assert {:ok, %{message_id: final_message_id, content: content}} =
             Core.send_message(session, "read mix")

    assert content =~ "Mock response after tool: defmodule Sample"

    assert {:ok, messages} = Core.messages(session)

    assert [
             %{role: :user, content: "read mix"},
             %{
               role: :assistant,
               content: "",
               tool_calls: [
                 %{id: "tool-read", name: "read_file", args: %{"path" => "mix.exs"}}
               ]
             },
             %{
               role: :tool,
               tool_call_id: "tool-read",
               name: "read_file",
               status: :ok,
               content: "defmodule Sample do\nend\n",
               summary: summary
             },
             %{role: :assistant, content: ^content}
           ] = messages

    assert summary =~ "read mix.exs"

    assert_receive {:core_event, {:session_started, %{session_id: _session_id}}}
    assert_receive {:core_event, {:agent_started, _session_id}}
    assert_receive {:core_event, {:turn_started, turn_id}}
    assert_receive {:core_event, {:message_started, _user_message_id, :user}}
    assert_receive {:core_event, {:message_finished, %{role: :user, content: "read mix"}}}
    assert_receive {:core_event, {:message_started, tool_request_message_id, :assistant}}

    assert_receive {:core_event,
                    {:message_finished,
                     %{
                       id: ^tool_request_message_id,
                       role: :assistant,
                       tool_calls: [%{id: "tool-read", name: "read_file"}]
                     }}}

    assert_receive {:core_event,
                    {:tool_started, "tool-read", "read_file", %{"path" => "mix.exs"}}}

    assert_receive {:core_event, {:tool_output, "tool-read", "defmodule Sample do\nend\n"}}
    assert_receive {:core_event, {:tool_finished, "tool-read", :ok, tool_summary}}
    assert tool_summary =~ "read mix.exs"
    assert_receive {:core_event, {:message_started, _tool_message_id, :tool}}

    assert_receive {:core_event,
                    {:message_finished, %{role: :tool, tool_call_id: "tool-read", status: :ok}}}

    assert_receive {:core_event, {:message_started, ^final_message_id, :assistant}}
    assert_receive {:core_event, {:message_delta, ^final_message_id, ^content}}

    assert_receive {:core_event,
                    {:message_finished,
                     %{id: ^final_message_id, role: :assistant, content: ^content}}}

    assert_receive {:core_event, {:turn_finished, ^turn_id, %{status: :ok}}}
    assert_receive {:core_event, {:agent_finished, _session_id}}

    assert :ok = Core.stop_session(session)
  end

  test "event log writes JSONL records" do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-core-event-log-#{System.unique_integer([:positive])}.jsonl"
      )

    assert {:ok, logger} = Core.EventLog.start_link(path: path)

    Core.EventBus.publish({:message_delta, "message-test", "logged"})

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
