defmodule Core.AgentSessionTest do
  use ExUnit.Case, async: false

  defmodule BlockingTool do
    @moduledoc false
    @behaviour Core.Tool

    @impl true
    def name, do: "blocking"
    @impl true
    def description, do: "blocks until killed"
    @impl true
    def schema, do: %{type: "object", properties: %{}}
    @impl true
    def safety, do: :read_only

    @impl true
    def run(args, _context) do
      send(Map.fetch!(args, "test"), {:tool_running, self()})
      Process.sleep(:infinity)
    end
  end

  defp start_blocking_session do
    script = [%{tool_calls: [%{id: "t1", name: "blocking", args: %{"test" => self()}}]}]

    {:ok, session} =
      Core.start_session(
        tools: [BlockingTool],
        permission_mode: :read_only,
        model_opts: [script: script]
      )

    session
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  test "abort returns :no_active_turn when the session is idle" do
    {:ok, session} = Core.start_session()
    assert {:error, :no_active_turn} = Core.abort(session)
    assert :ok = Core.stop_session(session)
  end

  test "messages/1 and turn_in_progress work while a turn is active" do
    session = start_blocking_session()
    caller = Task.async(fn -> Core.send_message(session, "go") end)

    assert_receive {:tool_running, _tool_pid}, 1_000

    assert {:ok, [%{role: :user, content: "go"}]} = Core.messages(session)
    assert {:error, :turn_in_progress} = Core.send_message(session, "again")

    assert :ok = Core.abort(session)
    assert {:error, :aborted} = Task.await(caller)
    assert :ok = Core.stop_session(session)
  end

  test "abort cancels the active turn and its tool task, keeping the session alive" do
    :ok = Core.EventBus.subscribe()
    session = start_blocking_session()
    caller = Task.async(fn -> Core.send_message(session, "go") end)

    assert_receive {:tool_running, tool_pid}, 1_000
    assert Process.alive?(tool_pid)

    assert :ok = Core.abort(session)
    assert {:error, :aborted} = Task.await(caller)

    wait_until(fn -> not Process.alive?(tool_pid) end)
    assert Process.alive?(session)

    assert_receive {:core_event, {:turn_finished, _turn_id, %{status: :cancelled}}}

    # Session is reusable for a new turn after an abort.
    assert {:error, :no_active_turn} = Core.abort(session)
    assert :ok = Core.stop_session(session)
  end

  test "a turn can run normally after a previous turn was aborted" do
    session = start_blocking_session()
    caller = Task.async(fn -> Core.send_message(session, "go") end)
    assert_receive {:tool_running, _tool_pid}, 1_000
    assert :ok = Core.abort(session)
    assert {:error, :aborted} = Task.await(caller)

    :ok = Core.configure_model(session, model_opts: [script: ["all done"]])
    assert {:ok, %{content: "all done"}} = Core.send_message(session, "again")

    assert :ok = Core.stop_session(session)
  end
end
