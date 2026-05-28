defmodule CoreTest do
  use ExUnit.Case, async: false

  defmodule CrashingModelClient do
    @behaviour Core.ModelClient

    @impl true
    def stream_chat(_messages, _tools, _opts, _event_sink) do
      raise "provider bug"
    end

    @impl true
    def complete_chat(_messages, _tools, _opts) do
      raise "provider bug"
    end
  end

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

  test "emits compact model call diagnostics" do
    :ok = Core.EventBus.subscribe()

    assert {:ok, session} =
             Core.start_session(model_opts: [script: ["diagnostic response"], api_key: "secret"])

    assert {:ok, %{content: "diagnostic response"}} = Core.send_message(session, "hello")

    assert_receive {:core_event, {:model_request, model_call_id, request}}

    assert request.model_opts.api_key == "[redacted]"
    assert request.message_count == 1

    assert [%{role: :user, content: %{text: "hello", bytes: 5, truncated: false}}] =
             request.messages

    assert request.tool_count > 0

    assert_receive {:core_event,
                    {:model_response, ^model_call_id,
                     %{
                       status: :ok,
                       response: %{
                         content: %{
                           text: "diagnostic response",
                           bytes: 19,
                           truncated: false
                         },
                         tool_calls: []
                       }
                     }}}

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

  test "does not cap tool iterations by default" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "agent-core-unlimited-tools-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "mix.exs"), "defmodule ManyTools do\nend\n")

    on_exit(fn -> File.rm_rf(workspace) end)

    script =
      Enum.map(1..5, fn index ->
        %{
          tool_calls: [
            %{
              id: "tool-read-#{index}",
              name: "read_file",
              args: %{"path" => "mix.exs"}
            }
          ]
        }
      end)

    assert {:ok, session} =
             Core.start_session(workspace_root: workspace, model_opts: [script: script])

    assert {:ok, %{content: content}} = Core.send_message(session, "read repeatedly")
    assert content =~ "Mock response after tool: defmodule ManyTools"

    assert {:ok, messages} = Core.messages(session)
    assert messages |> Enum.count(&match?(%{role: :tool}, &1)) == 5

    assert :ok = Core.stop_session(session)
  end

  test "honors an explicit tool iteration cap" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "agent-core-capped-tools-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "mix.exs"), "defmodule CappedTools do\nend\n")

    on_exit(fn -> File.rm_rf(workspace) end)

    script = [
      %{tool_calls: [%{id: "tool-read-1", name: "read_file", args: %{"path" => "mix.exs"}}]},
      %{tool_calls: [%{id: "tool-read-2", name: "read_file", args: %{"path" => "mix.exs"}}]}
    ]

    assert {:ok, session} =
             Core.start_session(
               workspace_root: workspace,
               max_tool_iterations: 1,
               model_opts: [script: script]
             )

    assert {:error, {:max_tool_iterations_exceeded, 1}} =
             Core.send_message(session, "read repeatedly")

    assert {:ok, messages} = Core.messages(session)
    assert messages |> Enum.count(&match?(%{role: :tool}, &1)) == 1

    assert %{
             role: :assistant,
             tool_calls: [%{id: "tool-read-2", name: "read_file", args: %{"path" => "mix.exs"}}]
           } = List.last(messages)

    assert :ok = Core.stop_session(session)
  end

  test "model client exceptions return errors without stopping the session" do
    assert {:ok, session} = Core.start_session(model_client: CrashingModelClient)

    assert {:error, {:model_client_exception, RuntimeError, "provider bug"}} =
             Core.send_message(session, "hello")

    assert Process.alive?(session)
    assert {:ok, [%{role: :user, content: "hello"}]} = Core.messages(session)

    assert :ok = Core.stop_session(session)
  end

  test "configures an unconfigured session for later turns" do
    assert {:ok, session} = Core.start_session(model_client: Core.ModelClient.Unconfigured)

    assert {:error, :model_not_configured} = Core.send_message(session, "hello")

    assert :ok =
             Core.configure_model(session,
               model_client: Core.ModelClient.Mock,
               model_opts: [script: ["configured"]],
               permission_mode: :trusted
             )

    assert {:ok, %{content: "configured"}} = Core.send_message(session, "hello again")

    state = :sys.get_state(session)
    assert state.permission_mode == :trusted

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

  test "event log stringifies runtime terms and redacts sensitive keys" do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-core-event-log-runtime-#{System.unique_integer([:positive])}.jsonl"
      )

    assert {:ok, logger} = Core.EventLog.start_link(path: path)

    Core.EventBus.publish(
      Core.Event.tool_started("tool-runtime", "blocking", %{
        "api_key" => "secret",
        "callback" => fn -> :ok end,
        "test" => self()
      })
    )

    assert_eventually(fn ->
      File.exists?(path) and File.read!(path) =~ ~S("event":"tool_started")
    end)

    contents = File.read!(path)
    assert contents =~ "[redacted]"
    refute contents =~ "secret"
    assert contents =~ "#PID"
    assert contents =~ "#Function"

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
