defmodule Tui.TerminalApp.Root do
  @moduledoc """
  TermUI root component for the agent terminal app.
  """

  use TermUI.Elm

  alias Tui.TerminalApp.CommandMenu
  alias Tui.TerminalApp.Prompt
  alias Tui.TerminalApp.Status
  alias Tui.TerminalApp.Transcript
  alias TermUI.Event
  alias TermUI.Renderer.Style

  defstruct height: 24,
            input: nil,
            notice: nil,
            panel: nil,
            pending_prompts: MapSet.new(),
            selected_command: 0,
            status: nil,
            submit_prompt: nil,
            task_supervisor: nil,
            transcript: nil,
            width: 80

  @type t :: %__MODULE__{
          height: pos_integer(),
          input: Prompt.t(),
          notice: String.t() | nil,
          panel: :help | :status | nil,
          pending_prompts: MapSet.t(reference()),
          selected_command: non_neg_integer(),
          status: Status.t(),
          submit_prompt: Tui.TerminalApp.submit_prompt() | nil,
          task_supervisor: GenServer.server() | nil,
          transcript: Transcript.t(),
          width: pos_integer()
        }

  @impl true
  def init(opts) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)

    %__MODULE__{
      height: height,
      input: Prompt.new(width: prompt_width(width)),
      status: Status.new(),
      submit_prompt: Keyword.get(opts, :submit_prompt),
      task_supervisor: Keyword.get(opts, :task_supervisor, Tui.TaskSupervisor),
      transcript: Transcript.new(),
      width: width
    }
  end

  @impl true
  def event_to_msg(%Event.Resize{width: width, height: height}, _state) do
    {:msg, {:resize, width, height}}
  end

  def event_to_msg(%Event.Key{key: "c", modifiers: modifiers} = event, _state) do
    if :ctrl in modifiers, do: {:msg, :quit}, else: {:msg, {:input_event, event}}
  end

  def event_to_msg(%Event.Key{key: :enter}, _state) do
    {:msg, :submit}
  end

  def event_to_msg(%Event.Key{key: :up}, state) do
    if command_menu_visible?(state), do: {:msg, {:move_command, -1}}, else: input_msg(:up)
  end

  def event_to_msg(%Event.Key{key: :down}, state) do
    if command_menu_visible?(state), do: {:msg, {:move_command, 1}}, else: input_msg(:down)
  end

  def event_to_msg(%Event.Key{key: :tab}, state) do
    if command_menu_visible?(state), do: {:msg, :complete_command}, else: input_msg(:tab)
  end

  def event_to_msg(%Event.Key{key: :escape}, state) do
    if command_menu_visible?(state), do: {:msg, :close_command_menu}, else: {:msg, :close_panel}
  end

  def event_to_msg(event, _state) do
    {:msg, {:input_event, event}}
  end

  @impl true
  def update({:resize, width, height}, state) do
    state =
      state
      |> Map.put(:width, max(20, width))
      |> Map.put(:height, max(10, height))
      |> Map.update!(:input, &Prompt.resize(&1, prompt_width(width)))

    {state}
  end

  def update(:submit, state) do
    submit_prompt_or_command(state)
  end

  def update({:set_submit_prompt, submit_prompt}, state) when is_function(submit_prompt, 1) do
    {%{state | submit_prompt: submit_prompt}, []}
  end

  def update({:submit_initial, prompt}, state) do
    {submit_prompt(state, prompt), []}
  end

  def update({:agent_event, event}, state) do
    state =
      %{
        state
        | status: Status.reduce_event(state.status, event),
          transcript: Transcript.append_event(state.transcript, event)
      }

    {state, []}
  end

  def update({:prompt_result, prompt_ref, result}, state) do
    pending_prompts = MapSet.delete(state.pending_prompts, prompt_ref)

    state =
      state
      |> Map.put(:pending_prompts, pending_prompts)
      |> Map.put(:notice, result_notice(result))

    {state, []}
  end

  def update({:move_command, delta}, state) do
    prompt = Prompt.value(state.input)
    selected_command = CommandMenu.move(state.selected_command, delta, prompt)
    {%{state | selected_command: selected_command}, []}
  end

  def update(:complete_command, state) do
    prompt = Prompt.value(state.input)

    case CommandMenu.selected(prompt, state.selected_command) do
      {:ok, command} ->
        input = Prompt.set_value(state.input, command.label)
        {%{state | input: input, selected_command: 0}, []}

      {:error, reason} ->
        {%{state | notice: format_error("command", reason)}, []}
    end
  end

  def update(:close_command_menu, state) do
    {%{state | input: Prompt.clear(state.input), selected_command: 0, notice: nil}, []}
  end

  def update(:close_panel, state) do
    {%{state | panel: nil, notice: nil}, []}
  end

  def update({:input_event, event}, state) do
    input = Prompt.handle_event(state.input, event)
    prompt = Prompt.value(input)
    selected_command = CommandMenu.clamp_index(state.selected_command, prompt)

    {%{state | input: input, selected_command: selected_command}, []}
  end

  def update(:quit, state), do: {state, [:quit]}

  def update(_msg, state), do: {state, []}

  @impl true
  def view(state) do
    stack(:vertical, [
      text(fit_line("Elixir Agent", state.width), style(:cyan, [:bold])),
      text(fit_line(Status.summary_line(state.status), state.width), style(:bright_black)),
      divider(state.width),
      transcript_view(state),
      divider(state.width),
      panel_view(state),
      command_menu_view(state),
      prompt_view(state),
      footer_view(state)
    ])
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

  defp submit_prompt(%{submit_prompt: submit_prompt} = state, prompt)
       when is_function(submit_prompt, 1) do
    prompt_ref = make_ref()
    runtime = self()

    with {:ok, _pid} <-
           start_prompt_task(state.task_supervisor, fn ->
             result = submit_prompt.(prompt)
             TermUI.Runtime.send_message(runtime, :root, {:prompt_result, prompt_ref, result})
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

  defp start_prompt_task(supervisor, fun) when is_function(fun, 0) do
    case resolve_supervisor(supervisor) do
      nil -> Task.start(fun)
      pid -> Task.Supervisor.start_child(pid, fun)
    end
  end

  defp resolve_supervisor(nil), do: nil
  defp resolve_supervisor(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp resolve_supervisor(name) when is_atom(name), do: Process.whereis(name)

  defp command_menu_visible?(state) do
    state.input
    |> Prompt.value()
    |> CommandMenu.visible?()
  end

  defp input_msg(key), do: {:msg, {:input_event, Event.key(key)}}

  defp transcript_view(state) do
    height = transcript_height(state)

    lines =
      state.transcript
      |> Transcript.visible_lines(state.width, height)
      |> fill_lines(height)

    lines
    |> Enum.map(&text(&1, nil))
    |> then(&stack(:vertical, &1))
  end

  defp panel_view(%{panel: nil}), do: empty()

  defp panel_view(%{panel: :help} = state) do
    render_panel("commands", CommandMenu.help_lines(), state.width)
  end

  defp panel_view(%{panel: :status} = state) do
    render_panel("status", Status.panel_lines(state.status), state.width)
  end

  defp command_menu_view(state) do
    prompt = Prompt.value(state.input)

    prompt
    |> CommandMenu.lines(state.selected_command, state.width)
    |> Enum.take(6)
    |> case do
      [] -> empty()
      lines -> render_panel("commands", lines, state.width)
    end
  end

  defp prompt_view(state) do
    stack(:horizontal, [
      text("> ", style(:green, [:bold])),
      Prompt.render(state.input)
    ])
  end

  defp footer_view(state) do
    line =
      state.notice ||
        if MapSet.size(state.pending_prompts) > 0 do
          "running..."
        else
          "Enter send | /status | /help | Ctrl+C quit"
        end

    text(fit_line(line, state.width), style(:bright_black))
  end

  defp render_panel(title, lines, width) do
    nodes =
      [
        text(fit_line("[#{title}]", width), style(:yellow, [:bold]))
        | Enum.map(lines, &text(fit_line(&1, width), nil))
      ]

    stack(:vertical, nodes)
  end

  defp transcript_height(state) do
    panel_rows =
      case {state.panel, command_menu_visible?(state)} do
        {nil, false} -> 0
        {nil, true} -> 7
        {_panel, false} -> 6
        {_panel, true} -> 12
      end

    max(4, state.height - panel_rows - 7)
  end

  defp fill_lines(lines, height) do
    padding = max(0, height - length(lines))
    List.duplicate("", padding) ++ lines
  end

  defp divider(width) do
    text(String.duplicate("-", max(1, width)), style(:bright_black))
  end

  defp prompt_width(width), do: max(10, width - 2)

  defp fit_line(line, width) when is_binary(line) do
    line
    |> String.graphemes()
    |> Enum.take(max(1, width))
    |> Enum.join()
  end

  defp style(color, attrs \\ []) do
    Style.new(fg: color, attrs: attrs)
  end

  defp result_notice({:ok, _reply}), do: nil
  defp result_notice({:error, reason}), do: format_error("prompt", reason)
  defp result_notice(result), do: format_error("prompt", result)

  defp format_error(scope, reason) do
    "#{scope} failed: #{inspect(reason)}"
  end
end
