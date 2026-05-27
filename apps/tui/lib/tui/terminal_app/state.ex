defmodule Tui.TerminalApp.State do
  @moduledoc """
  Owns terminal UI state transitions that are independent of ExRatatui.

  `Tui.TerminalApp.Root` translates terminal events into messages and delegates
  those messages here. Prompt submission remains an edge effect through the
  callback supplied by the embedding application.
  """

  alias Tui.TerminalApp.CommandMenu
  alias Tui.TerminalApp.Prompt
  alias Tui.TerminalApp.Status
  alias Tui.TerminalApp.Transcript

  @max_history 100

  defstruct height: 24,
            command_handler: nil,
            history: [],
            history_draft: "",
            history_index: nil,
            input: nil,
            notice: nil,
            panel: nil,
            pending_prompts: MapSet.new(),
            selected_command: 0,
            spinner: 0,
            status: nil,
            submit_prompt: nil,
            task_supervisor: nil,
            transcript: nil,
            width: 80

  @type t :: %__MODULE__{
          height: pos_integer(),
          command_handler: Tui.TerminalApp.command_handler() | nil,
          history: [String.t()],
          history_draft: String.t(),
          history_index: non_neg_integer() | nil,
          input: Prompt.t(),
          notice: String.t() | nil,
          panel: :help | :status | nil,
          pending_prompts: term(),
          selected_command: non_neg_integer(),
          spinner: non_neg_integer(),
          status: Status.t(),
          submit_prompt: Tui.TerminalApp.submit_prompt() | nil,
          task_supervisor: GenServer.server() | nil,
          transcript: Transcript.t(),
          width: pos_integer()
        }

  @doc """
  Builds the initial terminal UI state.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    width = opts |> Keyword.get(:width, 80) |> positive_integer_or(80)
    height = opts |> Keyword.get(:height, 24) |> positive_integer_or(24)

    %__MODULE__{
      command_handler: command_handler(Keyword.get(opts, :command_handler)),
      height: height,
      input: Prompt.new(width: prompt_width(width)),
      status: Status.new(),
      submit_prompt: prompt_callback(Keyword.get(opts, :submit_prompt)),
      task_supervisor: task_supervisor(Keyword.get(opts, :task_supervisor, Tui.TaskSupervisor)),
      transcript: Transcript.new(),
      width: width
    }
  end

  @doc """
  Applies one internal UI message to state.
  """
  @spec reduce(term(), t()) :: {t(), [atom()]}
  def reduce({:resize, width, height}, state) do
    width = positive_integer_or(width, state.width)
    height = positive_integer_or(height, state.height)

    state =
      state
      |> Map.put(:width, max(20, width))
      |> Map.put(:height, max(10, height))
      |> Map.update!(:input, &Prompt.resize(&1, prompt_width(width)))

    {state, []}
  end

  def reduce(:submit, state) do
    submit_prompt_or_command(state)
  end

  def reduce(:insert_newline, state) do
    {%{state | input: Prompt.insert_newline(state.input), history_index: nil}, []}
  end

  def reduce({:scroll, direction, height}, state) do
    width = Transcript.content_width(state.width)
    transcript = Transcript.scroll(state.transcript, direction, width, height)
    {%{state | transcript: transcript}, []}
  end

  def reduce(:clear_transcript, state) do
    {%{state | transcript: Transcript.clear(state.transcript)}, []}
  end

  def reduce({:history_prev, event}, state) do
    if prompt_cursor_at_top?(state),
      do: {history_prev(state), []},
      else: reduce({:input_event, event}, state)
  end

  def reduce({:history_next, event}, state) do
    if prompt_cursor_at_bottom?(state),
      do: {history_next(state), []},
      else: reduce({:input_event, event}, state)
  end

  def reduce({:set_submit_prompt, submit_prompt}, state) when is_function(submit_prompt, 1) do
    {%{state | submit_prompt: submit_prompt}, []}
  end

  def reduce({:set_command_handler, command_handler}, state)
      when is_function(command_handler, 2) do
    {%{state | command_handler: command_handler}, []}
  end

  def reduce({:append_notice, text}, state) when is_binary(text) do
    {append_notice(state, text), []}
  end

  def reduce({:submit_initial, prompt}, state) do
    {submit_prompt(state, prompt), []}
  end

  def reduce({:agent_event, event}, state) do
    now = System.monotonic_time(:millisecond)

    state =
      %{
        state
        | status: Status.reduce_event(state.status, event),
          transcript: Transcript.append_event(state.transcript, event, now)
      }

    {state, []}
  end

  def reduce({:command_result, command_ref, result}, state) do
    state =
      state
      |> finish_pending(command_ref)
      |> then(&handle_command_result(result, &1))

    {state, []}
  end

  def reduce({:prompt_result, prompt_ref, result}, state) do
    pending_prompts = MapSet.delete(state.pending_prompts, prompt_ref)

    state =
      state
      |> Map.put(:pending_prompts, pending_prompts)
      |> Map.put(:notice, result_notice(result))

    {state, []}
  end

  def reduce({:move_command, delta}, state) do
    prompt = Prompt.value(state.input)
    selected_command = CommandMenu.move(state.selected_command, delta, prompt)
    {%{state | selected_command: selected_command}, []}
  end

  def reduce(:complete_command, state) do
    prompt = Prompt.value(state.input)

    case CommandMenu.selected(prompt, state.selected_command) do
      {:ok, command} ->
        input = Prompt.set_value(state.input, command.label)
        {%{state | input: input, selected_command: 0}, []}

      {:error, reason} ->
        {%{state | notice: format_error("command", reason)}, []}
    end
  end

  def reduce(:close_command_menu, state) do
    {%{state | input: Prompt.clear(state.input), selected_command: 0, notice: nil}, []}
  end

  def reduce(:close_panel, state) do
    {%{state | panel: nil, notice: nil}, []}
  end

  def reduce({:input_event, event}, state) do
    before = Prompt.value(state.input)
    input = Prompt.handle_event(state.input, event)
    prompt = Prompt.value(input)
    selected_command = CommandMenu.clamp_index(state.selected_command, prompt)
    history_index = if prompt == before, do: state.history_index, else: nil

    {%{state | input: input, selected_command: selected_command, history_index: history_index},
     []}
  end

  def reduce(:spinner_tick, state), do: {%{state | spinner: state.spinner + 1}, []}

  def reduce(:quit, state), do: {state, [:quit]}
  def reduce(_msg, state), do: {state, []}

  @doc """
  Returns true when slash-command suggestions should handle navigation keys.
  """
  @spec command_menu_visible?(t()) :: boolean()
  def command_menu_visible?(state) do
    state.input
    |> Prompt.value()
    |> CommandMenu.visible?()
  end

  @doc """
  Returns true while at least one tool is still running.

  Drives the spinner animation: the root only arms the tick subscription while
  this holds, so the UI stays idle when nothing is in flight.
  """
  @spec running?(t()) :: boolean()
  def running?(state), do: Transcript.running?(state.transcript)

  @doc """
  Returns the prompt textarea width for a screen width.
  """
  @spec prompt_width(pos_integer()) :: pos_integer()
  def prompt_width(width), do: max(10, width - 2)

  defp prompt_cursor_at_top?(state) do
    {row, _col} = Prompt.cursor(state.input)
    row == 0
  end

  defp prompt_cursor_at_bottom?(state) do
    {row, _col} = Prompt.cursor(state.input)
    row >= Prompt.line_count(state.input) - 1
  end

  defp history_prev(%{history: []} = state), do: state

  defp history_prev(state) do
    {draft, index} =
      case state.history_index do
        nil -> {Prompt.value(state.input), 0}
        current -> {state.history_draft, min(current + 1, length(state.history) - 1)}
      end

    %{
      state
      | input: Prompt.set_value(state.input, Enum.at(state.history, index)),
        history_draft: draft,
        history_index: index
    }
  end

  defp history_next(%{history_index: nil} = state), do: state

  defp history_next(%{history_index: 0} = state) do
    %{state | input: Prompt.set_value(state.input, state.history_draft), history_index: nil}
  end

  defp history_next(state) do
    index = state.history_index - 1

    %{
      state
      | input: Prompt.set_value(state.input, Enum.at(state.history, index)),
        history_index: index
    }
  end

  defp record_history(state, prompt) do
    history =
      case state.history do
        [^prompt | _] = existing -> existing
        existing -> [prompt | existing]
      end
      |> Enum.take(@max_history)

    %{state | history: history, history_draft: "", history_index: nil}
  end

  defp submit_prompt_or_command(state) do
    prompt =
      state.input
      |> Prompt.value()
      |> String.trim()

    handle_submission(prompt, state)
  end

  defp handle_submission("", state), do: {state, []}
  defp handle_submission("/" <> _rest = prompt, state), do: execute_command(state, prompt)
  defp handle_submission(prompt, state), do: {submit_prompt(state, prompt), []}

  defp execute_command(state, prompt) do
    prompt
    |> CommandMenu.selected(state.selected_command)
    |> execute_selected_command(state)
  end

  defp execute_selected_command({:ok, %{id: command_id}}, state) do
    execute_command_id(command_id, state)
  end

  defp execute_selected_command({:error, reason}, state) do
    state
    |> put_error_notice("command", reason)
    |> noreply()
  end

  defp execute_command_id(:help, state) do
    state
    |> reset_command_input()
    |> show_panel(:help)
    |> noreply()
  end

  defp execute_command_id(:status, state) do
    state
    |> reset_command_input()
    |> show_panel(:status)
    |> noreply()
  end

  defp execute_command_id(:clear, state) do
    state
    |> reset_command_input()
    |> Map.update!(:transcript, &Transcript.clear/1)
    |> noreply()
  end

  defp execute_command_id(:quit, state) do
    {clear_input(state), [:quit]}
  end

  defp execute_command_id(command_id, state) do
    execute_app_command(command_id, state)
  end

  defp execute_app_command(command_id, %{command_handler: command_handler} = state)
       when is_function(command_handler, 2) do
    prompt = Prompt.value(state.input)
    command_ref = make_ref()
    runtime = self()
    context = %{prompt: prompt}
    state = reset_command_input(state)

    with {:ok, _pid} <-
           start_prompt_task(state.task_supervisor, fn ->
             result = invoke_callback(command_handler, [command_id, context])
             send(runtime, {:command_result, command_ref, result})
           end) do
      state
      |> start_pending_prompt(command_ref)
      |> noreply()
    else
      {:error, reason} ->
        state
        |> put_error_notice("command", reason)
        |> noreply()

      reason ->
        state
        |> put_error_notice("command", reason)
        |> noreply()
    end
  end

  defp execute_app_command(command_id, state) do
    state
    |> reset_command_input()
    |> put_error_notice("command", {:unhandled_command, command_id})
    |> noreply()
  end

  defp submit_prompt(%{submit_prompt: submit_prompt} = state, prompt)
       when is_function(submit_prompt, 1) do
    state = record_history(state, prompt)
    prompt_ref = make_ref()
    runtime = self()

    with {:ok, _pid} <-
           start_prompt_task(state.task_supervisor, fn ->
             result = invoke_callback(submit_prompt, [prompt])
             send(runtime, {:prompt_result, prompt_ref, result})
           end) do
      start_pending_prompt(state, prompt_ref)
    else
      {:error, reason} ->
        put_error_notice(state, "submit", reason)

      reason ->
        put_error_notice(state, "submit", reason)
    end
  end

  defp submit_prompt(state, _prompt) do
    %{state | notice: "submit failed: prompt callback is not configured"}
  end

  defp start_pending_prompt(state, prompt_ref) do
    %{
      state
      | input: Prompt.clear(state.input),
        notice: nil,
        panel: nil,
        pending_prompts: MapSet.put(state.pending_prompts, prompt_ref),
        selected_command: 0
    }
  end

  defp reset_command_input(state) do
    %{state | input: Prompt.clear(state.input), selected_command: 0}
  end

  defp clear_input(state) do
    %{state | input: Prompt.clear(state.input)}
  end

  defp show_panel(state, panel) do
    %{state | panel: panel}
  end

  defp put_error_notice(state, scope, reason) do
    %{state | notice: format_error(scope, reason)}
  end

  defp noreply(state), do: {state, []}

  defp finish_pending(state, ref) do
    %{state | pending_prompts: MapSet.delete(state.pending_prompts, ref)}
  end

  defp handle_command_result(:ok, state), do: %{state | notice: nil}
  defp handle_command_result({:ok, _value}, state), do: %{state | notice: nil}

  defp handle_command_result({:notice, text}, state) when is_binary(text),
    do: append_notice(state, text)

  defp handle_command_result({:error, reason}, state),
    do: put_error_notice(state, "command", reason)

  defp handle_command_result(result, state), do: put_error_notice(state, "command", result)

  defp append_notice(state, text) do
    transcript_text = ensure_trailing_newline(text)

    %{
      state
      | notice: String.trim(text),
        transcript: Transcript.append_text(transcript_text, state.transcript)
    }
  end

  defp ensure_trailing_newline(text) do
    if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
  end

  defp start_prompt_task(supervisor, fun) when is_function(fun, 0) do
    case resolve_supervisor(supervisor) do
      nil -> Task.start(fun)
      pid -> Task.Supervisor.start_child(pid, fun)
    end
  end

  defp resolve_supervisor(nil), do: nil
  defp resolve_supervisor(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp resolve_supervisor(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_supervisor({name, node} = server) when is_atom(name) and is_atom(node), do: server
  defp resolve_supervisor({:global, _name} = server), do: server
  defp resolve_supervisor({:via, module, _name} = server) when is_atom(module), do: server

  defp invoke_callback(callback, args) do
    apply(callback, args)
  rescue
    exception ->
      {:error, {:callback_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason ->
      {:error, {:callback_exit, reason}}

    kind, reason ->
      {:error, {:callback_throw, kind, reason}}
  end

  @spec positive_integer_or(term(), pos_integer()) :: pos_integer()
  defp positive_integer_or(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer_or(_value, fallback), do: fallback

  @spec prompt_callback(term()) :: Tui.TerminalApp.submit_prompt() | nil
  defp prompt_callback(callback) when is_function(callback, 1), do: callback
  defp prompt_callback(_callback), do: nil

  @spec command_handler(term()) :: Tui.TerminalApp.command_handler() | nil
  defp command_handler(callback) when is_function(callback, 2), do: callback
  defp command_handler(_callback), do: nil

  @spec task_supervisor(term()) :: GenServer.server() | nil
  defp task_supervisor(nil), do: nil
  defp task_supervisor(pid) when is_pid(pid), do: pid
  defp task_supervisor(name) when is_atom(name), do: name
  defp task_supervisor({name, node} = server) when is_atom(name) and is_atom(node), do: server
  defp task_supervisor({:global, _name} = server), do: server
  defp task_supervisor({:via, module, _name} = server) when is_atom(module), do: server
  defp task_supervisor(_server), do: nil

  defp result_notice({:ok, _reply}), do: nil
  defp result_notice(:ok), do: nil
  defp result_notice({:error, reason}), do: format_error("prompt", reason)
  defp result_notice(result), do: format_error("prompt", result)

  defp format_error(scope, reason) do
    "#{scope} failed: #{inspect(reason)}"
  end
end
