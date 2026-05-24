defmodule AgentCore.ToolExecutor do
  @moduledoc """
  Deterministic execution boundary for model tools.

  This module performs lookup, event emission, error normalization, and tool
  invocation. Later batch and permission layers can route through this same
  contract.
  """

  @output_limit 8_000

  @doc """
  Runs a named tool and emits the standard tool event sequence.
  """
  @spec run(String.t(), map(), keyword()) :: {:ok, AgentCore.Tool.result()} | {:error, term()}
  def run(name, args, opts \\ [])

  def run(name, args, opts) when is_binary(name) and is_map(args) do
    tool_call_id = Keyword.get_lazy(opts, :tool_call_id, &new_tool_call_id/0)
    tools = Keyword.get(opts, :tools, AgentCore.ToolRegistry.default_tools())
    context = tool_context(opts)

    with {:ok, tool} <- AgentCore.ToolRegistry.fetch(name, tools) do
      emit(AgentCore.Event.tool_started(tool_call_id, tool.name(), args))

      tool
      |> safe_run(args, context)
      |> finish(tool_call_id, tool.name())
    else
      {:error, reason} = error ->
        emit(AgentCore.Event.error(:tool, reason))
        emit(AgentCore.Event.tool_finished(tool_call_id, :error, summarize_error(reason)))
        error
    end
  end

  def run(name, args, opts) when is_atom(name) do
    run(Atom.to_string(name), args, opts)
  end

  def run(name, args, _opts) do
    {:error, {:invalid_tool_call, name, args}}
  end

  defp finish({:ok, result}, tool_call_id, _name) when is_map(result) do
    result
    |> Map.get(:output)
    |> emit_output(tool_call_id)

    emit(AgentCore.Event.tool_finished(tool_call_id, :ok, Map.get(result, :summary, "completed")))

    {:ok, result}
  end

  defp finish({:error, reason}, tool_call_id, _name) do
    emit(AgentCore.Event.error(:tool, reason))
    emit(AgentCore.Event.tool_finished(tool_call_id, :error, summarize_error(reason)))
    {:error, reason}
  end

  defp finish(other, tool_call_id, name) do
    reason = {:invalid_tool_result, name, other}
    emit(AgentCore.Event.error(:tool, reason))
    emit(AgentCore.Event.tool_finished(tool_call_id, :error, summarize_error(reason)))
    {:error, reason}
  end

  defp safe_run(tool, args, context) do
    tool.run(args, context)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  end

  defp emit_output(nil, _tool_call_id), do: :ok
  defp emit_output("", _tool_call_id), do: :ok

  defp emit_output(output, tool_call_id) when is_binary(output) do
    emit(AgentCore.Event.tool_output(tool_call_id, truncate(output)))
  end

  defp tool_context(opts) do
    %{workspace_root: Keyword.get_lazy(opts, :workspace_root, &File.cwd!/0)}
  end

  defp truncate(output) when byte_size(output) <= @output_limit, do: output

  defp truncate(output) do
    binary_part(output, 0, @output_limit) <> "\n...[truncated]"
  end

  defp summarize_error(reason) do
    inspect(reason, charlists: :as_lists)
  end

  defp emit(event), do: AgentCore.EventBus.publish(event)

  defp new_tool_call_id do
    "tool-" <>
      (System.unique_integer([:positive, :monotonic])
       |> Integer.to_string(36))
  end
end
