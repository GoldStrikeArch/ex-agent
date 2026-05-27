defmodule Core.ToolSchedulerTest do
  use ExUnit.Case, async: false

  alias Core.ToolScheduler

  defmodule BarrierTool do
    @moduledoc false
    @behaviour Core.Tool

    @impl true
    def name, do: "barrier"
    @impl true
    def description, do: "test barrier tool"
    @impl true
    def schema, do: %{type: "object", properties: %{}}
    @impl true
    def safety, do: :read_only

    @impl true
    def run(args, _context) do
      test = Map.fetch!(args, "test")
      label = Map.fetch!(args, "label")
      send(test, {:started, label, self()})

      receive do
        :proceed -> {:ok, %{output: "done-#{label}", summary: "done-#{label}"}}
      after
        5_000 -> {:error, :tool_never_proceeded}
      end
    end
  end

  defmodule CrashTool do
    @moduledoc false
    @behaviour Core.Tool

    @impl true
    def name, do: "crash"
    @impl true
    def description, do: "test crashing tool"
    @impl true
    def schema, do: %{type: "object", properties: %{}}
    @impl true
    def safety, do: :read_only

    @impl true
    def run(args, _context) do
      case Map.fetch!(args, "mode") do
        "raise" -> raise "boom"
        "exit" -> exit(:boom)
        "kill" -> Process.exit(self(), :kill)
      end
    end
  end

  defmodule SleepTool do
    @moduledoc false
    @behaviour Core.Tool

    @impl true
    def name, do: "sleep"
    @impl true
    def description, do: "test sleeping tool"
    @impl true
    def schema, do: %{type: "object", properties: %{}}
    @impl true
    def safety, do: :read_only

    @impl true
    def run(args, _context) do
      Process.sleep(Map.fetch!(args, "ms"))
      {:ok, %{output: "slept", summary: "slept"}}
    end
  end

  defp call(id, name, args), do: %{id: id, name: name, args: args}

  test "sibling read tools execute concurrently and return results in source order" do
    calls = [
      call("1", "barrier", %{"test" => self(), "label" => "a"}),
      call("2", "barrier", %{"test" => self(), "label" => "b"}),
      call("3", "barrier", %{"test" => self(), "label" => "c"})
    ]

    batch = Task.async(fn -> ToolScheduler.run_batch(calls, tools: [BarrierTool]) end)

    # All three start before any is allowed to finish: proves real parallelism.
    assert_receive {:started, "a", pid_a}
    assert_receive {:started, "b", pid_b}
    assert_receive {:started, "c", pid_c}

    # Finish out of order; results must still come back in source order.
    send(pid_c, :proceed)
    send(pid_a, :proceed)
    send(pid_b, :proceed)

    %{status: :ok, results: results} = Task.await(batch)

    assert Enum.map(results, & &1.call.id) == ["1", "2", "3"]

    assert Enum.map(results, & &1.result) == [
             {:ok, %{output: "done-a", summary: "done-a"}},
             {:ok, %{output: "done-b", summary: "done-b"}},
             {:ok, %{output: "done-c", summary: "done-c"}}
           ]
  end

  test "a crashing tool does not stop the batch and yields a child error" do
    calls = [
      call("1", "crash", %{"mode" => "raise"}),
      call("2", "crash", %{"mode" => "exit"}),
      call("3", "crash", %{"mode" => "kill"}),
      call("4", "sleep", %{"ms" => 0})
    ]

    %{status: status, results: results} =
      ToolScheduler.run_batch(calls, tools: [CrashTool, SleepTool])

    statuses = Enum.map(results, & &1.status)
    assert statuses == [:error, :error, :cancelled, :ok]
    assert status == :cancelled
    assert Enum.map(results, & &1.call.id) == ["1", "2", "3", "4"]
  end

  test "a per-call timeout becomes a timeout result without stopping the batch" do
    calls = [
      call("1", "sleep", %{"ms" => 2_000, "timeout_ms" => 20}),
      call("2", "sleep", %{"ms" => 0})
    ]

    %{status: status, results: results} = ToolScheduler.run_batch(calls, tools: [SleepTool])

    assert Enum.map(results, & &1.status) == [:timeout, :ok]
    assert status == :timeout
    assert {:error, :tool_timeout} = Enum.at(results, 0).result
  end

  test "batch status reflects the most severe child outcome" do
    calls = [
      call("1", "sleep", %{"ms" => 0}),
      call("2", "crash", %{"mode" => "raise"})
    ]

    assert %{status: :error} = ToolScheduler.run_batch(calls, tools: [CrashTool, SleepTool])
  end

  test "emits batch lifecycle events" do
    :ok = Core.EventBus.subscribe()

    ToolScheduler.run_batch([call("1", "sleep", %{"ms" => 0})],
      tools: [SleepTool],
      batch_id: "batch-test"
    )

    assert_receive {:core_event, {:batch_started, "batch-test", 1}}
    assert_receive {:core_event, {:batch_finished, "batch-test", :ok}}
  end

  describe "write coordination" do
    setup do
      workspace =
        Path.join(System.tmp_dir!(), "agent-scheduler-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)
      %{workspace: workspace}
    end

    test "same-file writes serialize without lock errors", %{workspace: workspace} do
      a = String.duplicate("a", 500)
      b = String.duplicate("b", 500)

      calls = [
        call("1", "write_file", %{"path" => "same.txt", "content" => a}),
        call("2", "write_file", %{"path" => "same.txt", "content" => b})
      ]

      %{results: results} =
        ToolScheduler.run_batch(calls, workspace_root: workspace, permission_mode: :trusted)

      assert Enum.all?(results, &match?(%{status: :ok}, &1))
      # Last writer wins, but the file is never a corrupted interleave of both.
      assert File.read!(Path.join(workspace, "same.txt")) in [a, b]
    end

    test "cross-file writes both succeed concurrently", %{workspace: workspace} do
      calls = [
        call("1", "write_file", %{"path" => "one.txt", "content" => "one"}),
        call("2", "write_file", %{"path" => "two.txt", "content" => "two"})
      ]

      %{status: :ok, results: results} =
        ToolScheduler.run_batch(calls, workspace_root: workspace, permission_mode: :trusted)

      assert Enum.all?(results, &match?(%{status: :ok}, &1))
      assert File.read!(Path.join(workspace, "one.txt")) == "one"
      assert File.read!(Path.join(workspace, "two.txt")) == "two"
    end

    test "shell calls overlap in trusted mode", %{workspace: workspace} do
      calls = [
        call("1", "shell", %{"command" => "sleep 0.3"}),
        call("2", "shell", %{"command" => "sleep 0.3"}),
        call("3", "shell", %{"command" => "sleep 0.3"})
      ]

      {elapsed_us, %{status: :ok}} =
        :timer.tc(fn ->
          ToolScheduler.run_batch(calls, workspace_root: workspace, permission_mode: :trusted)
        end)

      # Sequential execution would need ~0.9s; concurrent stays well under.
      assert elapsed_us < 700_000
    end
  end
end
