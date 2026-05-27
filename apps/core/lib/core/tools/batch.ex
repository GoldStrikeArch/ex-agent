defmodule Core.Tools.Batch do
  @moduledoc """
  Runs several tool calls in parallel through `Core.ToolScheduler`.

  The model can request explicit parallelism with one `batch` call instead of
  emitting many sibling tool calls. Each nested call goes through the normal
  permission checks and tool lookup. The `batch` tool itself is `:read_only`; a
  nested write or shell call is authorized on its own safety level.

  Nested `batch` calls are rejected with `{:nested_batch_not_supported, id}`.
  Output is compact ordered JSON with each child's `id`, `tool`, `status`, and a
  truncated `content` or `error`.
  """

  @behaviour Core.Tool

  alias Core.Tools.Args

  @content_limit 2_000

  @impl true
  def name, do: "batch"

  @impl true
  def description,
    do:
      "Run multiple tool calls in parallel. Provide a list of {tool, args} calls; results return in order."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["calls"],
      properties: %{
        calls: %{
          type: "array",
          items: %{
            type: "object",
            required: ["tool", "args"],
            properties: %{
              id: %{type: "string"},
              tool: %{type: "string"},
              args: %{type: "object"}
            }
          }
        },
        timeout_ms: %{type: "integer"}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, raw_calls} <- fetch_calls(args),
         {:ok, calls} <- normalize_calls(raw_calls) do
      batch = Core.ToolScheduler.run_batch(calls, scheduler_opts(args, context))
      {:ok, summarize(batch)}
    end
  end

  defp fetch_calls(args) do
    case Args.get(args, :calls) do
      calls when is_list(calls) and calls != [] -> {:ok, calls}
      other -> {:error, {:invalid_argument, :calls, other}}
    end
  end

  defp normalize_calls(raw_calls) do
    raw_calls
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case normalize_call(raw) do
        {:ok, call} -> {:cont, {:ok, [call | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp normalize_call(%{} = raw) do
    tool = Args.get(raw, :tool)
    args = Args.get(raw, :args, %{})
    id = Args.get(raw, :id)

    cond do
      not (is_binary(tool) and tool != "") -> {:error, {:invalid_batch_call, :tool, raw}}
      not is_map(args) -> {:error, {:invalid_batch_call, :args, raw}}
      true -> {:ok, %{id: call_id(id), name: tool, args: args}}
    end
  end

  defp normalize_call(raw), do: {:error, {:invalid_batch_call, raw}}

  defp call_id(id) when is_binary(id) and id != "", do: id

  defp call_id(_id) do
    "batch-call-" <>
      (System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36))
  end

  defp scheduler_opts(args, context) do
    [
      reject_nested_batch: true,
      tools: Map.get(context, :tools, Core.ToolRegistry.default_tools()),
      workspace_root: Map.get(context, :workspace_root),
      permission_mode: Map.get(context, :permission_mode, :read_only),
      file_lock_manager: Map.get(context, :file_lock_manager, Core.FileLockManager),
      structural_backend:
        Map.get(context, :structural_backend, Core.Structural.Backend.Unavailable),
      tool_timeout_ms: Map.get(context, :tool_timeout_ms),
      batch_timeout_ms: batch_timeout(args, context)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp batch_timeout(args, context) do
    case Args.optional_integer(args, :timeout_ms, 1, 3_600_000) do
      {:ok, ms} when is_integer(ms) -> ms
      _other -> Map.get(context, :batch_timeout_ms)
    end
  end

  defp summarize(%{status: status, results: results}) do
    children = Enum.map(results, &child_summary/1)

    %{
      status: status,
      output: Core.Json.encode!(children),
      summary: "batch #{status}: #{counts(results)}"
    }
  end

  defp child_summary(%{call: call, result: result, status: status}) do
    base = %{id: call.id, tool: call.name, status: Atom.to_string(status)}
    Map.merge(base, content_or_error(result))
  end

  defp content_or_error({:ok, result}) do
    %{summary: Map.get(result, :summary, "completed"), content: truncate(content(result))}
  end

  defp content_or_error({:error, reason}) do
    %{error: inspect(reason, charlists: :as_lists)}
  end

  defp content(%{output: output}) when is_binary(output), do: output
  defp content(%{summary: summary}) when is_binary(summary), do: summary
  defp content(result), do: inspect(result, charlists: :as_lists)

  defp truncate(content) when byte_size(content) <= @content_limit, do: content

  defp truncate(content) do
    binary_part(content, 0, @content_limit) <> "...[truncated]"
  end

  defp counts(results) do
    results
    |> Enum.frequencies_by(& &1.status)
    |> Enum.sort()
    |> Enum.map_join(", ", fn {status, count} -> "#{count} #{status}" end)
  end
end
