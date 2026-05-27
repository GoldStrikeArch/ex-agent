defmodule Core.TurnRunner do
  @moduledoc """
  Runs one agent turn: the model/tool loop for a single user prompt.

  The runner executes inside a task supervised by `Core.TurnTaskSupervisor`, not
  inside the `Core.AgentSession` GenServer. The session stays responsive (it can
  answer `messages/1` and `abort/1`) while a turn streams and runs tools.

  The runner owns no session state. It receives an immutable turn spec, emits
  events through `Core.EventBus`, and returns the turn outcome plus the final
  message list for the session to persist:

    * `{:ok, %{message_id: id, content: content}, messages}`
    * `{:error, reason, messages}`

  Tool calls run through `Core.ToolScheduler`. The runner starts a per-turn
  `Task.Supervisor` linked to itself so that cancelling the turn task cascades to
  every in-flight tool task.
  """

  @type spec :: %{
          required(:session_id) => String.t(),
          required(:turn_id) => String.t(),
          required(:assistant_message_id) => String.t(),
          required(:messages) => [Core.AgentSession.message()],
          required(:model_client) => module(),
          required(:model_opts) => keyword(),
          required(:tools) => [module()],
          required(:workspace_root) => Path.t(),
          required(:permission_mode) => Core.PermissionPolicy.mode(),
          required(:file_lock_manager) => GenServer.server(),
          required(:max_tool_iterations) => non_neg_integer() | :infinity,
          required(:tool_timeout_ms) => pos_integer(),
          required(:batch_timeout_ms) => pos_integer(),
          required(:structural_backend) => module()
        }

  @type outcome ::
          {:ok, %{message_id: String.t(), content: String.t()}, [Core.AgentSession.message()]}
          | {:error, term(), [Core.AgentSession.message()]}

  @doc """
  Runs the turn described by `spec` to completion and returns its outcome.
  """
  @spec run(spec()) :: outcome()
  def run(spec) do
    {:ok, tool_supervisor} = Task.Supervisor.start_link()

    try do
      run_model_loop(spec.messages, spec, tool_supervisor, 0, spec.assistant_message_id)
    after
      Supervisor.stop(tool_supervisor, :normal)
    end
  end

  defp run_model_loop(messages, spec, tool_supervisor, tool_iterations, assistant_message_id) do
    publish(Core.Event.message_started(assistant_message_id, :assistant))

    spec
    |> stream_chat(messages, assistant_message_id)
    |> normalize_model_response()
    |> continue_model_loop(messages, spec, tool_supervisor, tool_iterations, assistant_message_id)
  end

  defp stream_chat(spec, messages, assistant_message_id) do
    spec.model_client.stream_chat(
      messages,
      Core.ToolRegistry.schemas(spec.tools),
      Keyword.put_new(spec.model_opts, :session_id, spec.session_id),
      message_delta_sink(assistant_message_id)
    )
  rescue
    exception ->
      {:error, {:model_client_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason ->
      {:error, {:model_client_exit, reason}}

    kind, reason ->
      {:error, {:model_client_throw, kind, reason}}
  end

  defp message_delta_sink(message_id) do
    fn delta -> publish(Core.Event.message_delta(message_id, delta)) end
  end

  defp normalize_model_response({:ok, content}) when is_binary(content) do
    {:ok, %{content: content, tool_calls: []}}
  end

  defp normalize_model_response({:ok, response}) when is_map(response) do
    content = response_content(response)
    tool_calls = Map.get(response, :tool_calls, Map.get(response, "tool_calls", []))

    with {:ok, calls} <- Core.ToolCall.normalize_all(tool_calls) do
      {:ok, %{content: content, tool_calls: calls}}
    end
  end

  defp normalize_model_response({:error, reason}), do: {:error, reason}
  defp normalize_model_response(response), do: {:error, {:invalid_model_response, response}}

  defp response_content(%{content: content}) when is_binary(content), do: content
  defp response_content(%{"content" => content}) when is_binary(content), do: content
  defp response_content(_response), do: ""

  defp continue_model_loop(
         {:ok, %{content: content, tool_calls: []}},
         messages,
         _spec,
         _tool_supervisor,
         _tool_iterations,
         assistant_message_id
       ) do
    assistant_message = %{role: :assistant, content: content}
    publish_message_finished(assistant_message_id, assistant_message)

    {:ok, %{message_id: assistant_message_id, content: content}, messages ++ [assistant_message]}
  end

  defp continue_model_loop(
         {:ok, %{content: content, tool_calls: tool_calls}},
         messages,
         spec,
         tool_supervisor,
         tool_iterations,
         assistant_message_id
       ) do
    assistant_message = assistant_message(content, tool_calls)
    publish_message_finished(assistant_message_id, assistant_message)

    continue_after_tool_request(
      messages,
      assistant_message,
      tool_calls,
      spec,
      tool_supervisor,
      tool_iterations
    )
  end

  defp continue_model_loop(
         {:error, reason},
         messages,
         _spec,
         _tool_supervisor,
         _tool_iterations,
         _assistant_message_id
       ) do
    {:error, reason, messages}
  end

  defp assistant_message("", tool_calls),
    do: %{role: :assistant, content: "", tool_calls: tool_calls}

  defp assistant_message(content, tool_calls),
    do: %{role: :assistant, content: content, tool_calls: tool_calls}

  defp continue_after_tool_request(
         messages,
         assistant_message,
         tool_calls,
         spec,
         tool_supervisor,
         tool_iterations
       ) do
    if tool_limit_reached?(tool_iterations, spec.max_tool_iterations) do
      {:error, {:max_tool_iterations_exceeded, spec.max_tool_iterations},
       messages ++ [assistant_message]}
    else
      tool_messages = run_tool_calls(tool_calls, spec, tool_supervisor)
      next_messages = messages ++ [assistant_message | tool_messages]

      run_model_loop(next_messages, spec, tool_supervisor, tool_iterations + 1, new_message_id())
    end
  end

  defp tool_limit_reached?(_tool_iterations, :infinity), do: false
  defp tool_limit_reached?(tool_iterations, max) when is_integer(max), do: tool_iterations >= max

  defp run_tool_calls(tool_calls, spec, tool_supervisor) do
    tool_calls
    |> Core.ToolScheduler.run_batch(scheduler_opts(spec, tool_supervisor))
    |> Map.fetch!(:results)
    |> Enum.map(&record_tool_result/1)
  end

  defp scheduler_opts(spec, tool_supervisor) do
    [
      tools: spec.tools,
      workspace_root: spec.workspace_root,
      permission_mode: spec.permission_mode,
      file_lock_manager: spec.file_lock_manager,
      structural_backend: spec.structural_backend,
      tool_timeout_ms: spec.tool_timeout_ms,
      batch_timeout_ms: spec.batch_timeout_ms,
      task_supervisor: tool_supervisor
    ]
  end

  defp record_tool_result(%{call: call, result: result}) do
    message = tool_result_message(call, result)
    message_id = new_message_id()

    publish(Core.Event.message_started(message_id, :tool))
    publish_message_finished(message_id, message)
    message
  end

  defp tool_result_message(call, {:ok, result}) do
    %{
      role: :tool,
      tool_call_id: call.id,
      name: call.name,
      status: :ok,
      content: tool_content(result),
      summary: Map.get(result, :summary, "completed")
    }
  end

  defp tool_result_message(call, {:error, reason}) do
    summary = inspect(reason, charlists: :as_lists)

    %{
      role: :tool,
      tool_call_id: call.id,
      name: call.name,
      status: :error,
      content: summary,
      summary: summary
    }
  end

  defp tool_content(%{output: output}) when is_binary(output), do: output
  defp tool_content(%{summary: summary}) when is_binary(summary), do: summary
  defp tool_content(result), do: inspect(result, charlists: :as_lists)

  defp publish_message_finished(message_id, message) do
    publish(Core.Event.message_finished(Map.put(message, :id, message_id)))
  end

  defp publish(event), do: Core.EventBus.publish(event)

  defp new_message_id do
    "message-" <>
      (System.unique_integer([:positive, :monotonic])
       |> Integer.to_string(36))
  end
end
