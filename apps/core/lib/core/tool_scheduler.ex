defmodule Core.ToolScheduler do
  @moduledoc """
  Runs a batch of tool calls with maximum parallelism.

  Both provider sibling tool calls and the model-facing `batch` tool route
  through `run_batch/2`. Every authorized call starts immediately on its own
  supervised task; there is no scheduler concurrency cap. OS limits,
  permissions, file locks, per-call timeouts, and cancellation still apply.

  ## Ordering

  Tool lifecycle events (`tool_started`, `tool_output`, `tool_finished`) are
  emitted from inside each task, so they interleave in real completion order.
  The returned `:results` list is always in the original call (assistant source)
  order so the model sees deterministic tool messages.

  ## Failure isolation

  Tasks are started with `Task.Supervisor.async_nolink/3` and monitored, so a
  crashing, exiting, or killed tool becomes a structured error result instead of
  taking down the batch. Per-call timeouts and the overall batch timeout shut
  down slow tasks and record timeout errors.

  ## Cancellation

  Pass `:task_supervisor` with a `Task.Supervisor` linked to the owning turn so
  that terminating the turn cascades to every in-flight tool task.
  """

  @type call :: Core.ToolCall.t()
  @type child_status :: :ok | :error | :timeout | :cancelled
  @type result_entry :: %{
          call: call(),
          result: {:ok, Core.Tool.result()} | {:error, term()},
          status: child_status()
        }
  @type batch_result :: %{batch_id: String.t(), status: child_status(), results: [result_entry()]}

  @default_tool_timeout_ms 120_000
  @default_batch_timeout_ms 300_000

  @doc """
  Runs `calls` in parallel and returns ordered results plus a batch status.

  ## Options

    * `:tools` - tool modules available for lookup.
    * `:workspace_root`, `:permission_mode`, `:file_lock_manager`,
      `:structural_backend` - forwarded to each tool through `Core.ToolExecutor`.
    * `:tool_timeout_ms` - default per-call timeout (default `120_000`).
    * `:batch_timeout_ms` - overall batch timeout (default `300_000`).
    * `:task_supervisor` - `Task.Supervisor` to run tool tasks under
      (default `Core.ToolTaskSupervisor`).
    * `:reject_nested_batch` - when true, calls to the `batch` tool return a
      `{:nested_batch_not_supported, id}` error instead of running.
    * `:batch_id` - explicit batch id; generated when absent.
    * `:emit_events` - emit `batch_started`/`batch_finished` (default `true`).
  """
  @spec run_batch([call()], keyword()) :: batch_result()
  def run_batch(calls, opts \\ []) when is_list(calls) do
    batch_id = Keyword.get_lazy(opts, :batch_id, &new_batch_id/0)
    emit_events? = Keyword.get(opts, :emit_events, true)

    if emit_events?, do: emit(Core.Event.batch_started(batch_id, length(calls)))

    results = calls |> start_tasks(opts) |> collect(%{})
    ordered = order_results(calls, results)
    status = batch_status(ordered)

    if emit_events?, do: emit(Core.Event.batch_finished(batch_id, status))

    %{batch_id: batch_id, status: status, results: ordered}
  end

  defp start_tasks(calls, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, Core.ToolTaskSupervisor)
    batch_deadline = now_ms() + batch_timeout(opts)

    calls
    |> Enum.with_index()
    |> Map.new(fn {call, index} ->
      task = Task.Supervisor.async_nolink(supervisor, fn -> run_one(call, opts) end)
      deadline = min(batch_deadline, now_ms() + call_timeout(call, opts))
      {task.ref, %{index: index, call: call, task: task, deadline: deadline}}
    end)
  end

  defp run_one(call, opts) do
    if Keyword.get(opts, :reject_nested_batch, false) and batch_name?(call.name) do
      {:error, {:nested_batch_not_supported, call.id}}
    else
      execute(call, opts)
    end
  end

  defp execute(call, opts) do
    Core.ToolExecutor.run(call.name, call.args, executor_opts(call, opts))
  catch
    kind, reason -> {:error, {:tool_task_crash, kind, reason}}
  end

  defp executor_opts(call, opts) do
    [
      tool_call_id: call.id,
      tools: Keyword.get(opts, :tools, Core.ToolRegistry.default_tools()),
      workspace_root: Keyword.get(opts, :workspace_root),
      permission_mode: Keyword.get(opts, :permission_mode, :read_only),
      file_lock_manager: Keyword.get(opts, :file_lock_manager, Core.FileLockManager),
      structural_backend:
        Keyword.get(opts, :structural_backend, Core.Structural.Backend.Unavailable),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, @default_tool_timeout_ms),
      batch_timeout_ms: Keyword.get(opts, :batch_timeout_ms, @default_batch_timeout_ms)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp collect(pending, results) when map_size(pending) == 0, do: results

  defp collect(pending, results) do
    now = now_ms()

    timeout =
      pending |> Enum.map(fn {_ref, entry} -> entry.deadline end) |> Enum.min() |> sub(now)

    receive do
      {ref, value} when is_map_key(pending, ref) ->
        {entry, pending} = Map.pop(pending, ref)
        Process.demonitor(ref, [:flush])
        collect(pending, Map.put(results, entry.index, value))

      {:DOWN, ref, :process, _pid, reason} when is_map_key(pending, ref) ->
        {entry, pending} = Map.pop(pending, ref)
        collect(pending, Map.put(results, entry.index, {:error, {:tool_task_exit, reason}}))
    after
      timeout -> expire(pending, results, now)
    end
  end

  defp expire(pending, results, now) do
    {expired, alive} = Enum.split_with(pending, fn {_ref, entry} -> entry.deadline <= now end)

    results =
      Enum.reduce(expired, results, fn {_ref, entry}, acc ->
        Map.put(acc, entry.index, shutdown_result(entry.task))
      end)

    collect(Map.new(alive), results)
  end

  defp shutdown_result(task) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      _other -> {:error, :tool_timeout}
    end
  end

  defp order_results(calls, results) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn {call, index} ->
      result = Map.get(results, index, {:error, :tool_timeout})
      %{call: call, result: result, status: child_status(result)}
    end)
  end

  defp child_status({:ok, _result}), do: :ok
  defp child_status({:error, :tool_timeout}), do: :timeout
  defp child_status({:error, :batch_timeout}), do: :timeout
  defp child_status({:error, {:tool_task_exit, :killed}}), do: :cancelled
  defp child_status({:error, _reason}), do: :error

  defp batch_status([]), do: :ok

  defp batch_status(entries) do
    entries
    |> Enum.map(&severity(&1.status))
    |> Enum.max()
    |> status_for_severity()
  end

  defp severity(:ok), do: 0
  defp severity(:error), do: 1
  defp severity(:timeout), do: 2
  defp severity(:cancelled), do: 3

  defp status_for_severity(0), do: :ok
  defp status_for_severity(1), do: :error
  defp status_for_severity(2), do: :timeout
  defp status_for_severity(3), do: :cancelled

  defp call_timeout(call, opts) do
    case timeout_arg(call.args) do
      {:ok, ms} -> ms
      :error -> Keyword.get(opts, :tool_timeout_ms, @default_tool_timeout_ms)
    end
  end

  defp timeout_arg(args) when is_map(args) do
    case Map.get(args, "timeout_ms", Map.get(args, :timeout_ms)) do
      ms when is_integer(ms) and ms > 0 -> {:ok, ms}
      _other -> :error
    end
  end

  defp timeout_arg(_args), do: :error

  defp batch_timeout(opts), do: Keyword.get(opts, :batch_timeout_ms, @default_batch_timeout_ms)

  defp batch_name?(name) when is_binary(name), do: String.downcase(name) == "batch"
  defp batch_name?(_name), do: false

  defp sub(deadline, now), do: max(deadline - now, 0)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp emit(event), do: Core.EventBus.publish(event)

  defp new_batch_id do
    "batch-" <>
      (System.unique_integer([:positive, :monotonic])
       |> Integer.to_string(36))
  end
end
