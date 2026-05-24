defmodule Tui.TerminalApp.Root do
  @moduledoc """
  ExRatatui root application for the agent terminal UI.
  """

  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Frame
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph
  alias Tui.TerminalApp.CommandMenu
  alias Tui.TerminalApp.Prompt
  alias Tui.TerminalApp.Status
  alias Tui.TerminalApp.Transcript

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

  @doc """
  Builds the initial root state.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
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
  def mount(opts) do
    {:ok, new(opts)}
  end

  @impl true
  def handle_event(event, state) do
    event
    |> event_to_msg(state)
    |> apply_msg(state)
  end

  @impl true
  def handle_info(msg, state) do
    msg
    |> reduce(state)
    |> callback_result()
  end

  @doc """
  Converts an ExRatatui terminal event into an internal UI message.
  """
  @spec event_to_msg(Event.Key.t() | Event.Resize.t() | term(), t()) :: {:msg, term()}
  def event_to_msg(%Event.Resize{width: width, height: height}, _state) do
    {:msg, {:resize, width, height}}
  end

  def event_to_msg(%Event.Key{code: "c", modifiers: modifiers} = event, _state) do
    if ctrl?(modifiers), do: {:msg, :quit}, else: {:msg, {:input_event, event}}
  end

  def event_to_msg(%Event.Key{code: "enter"}, _state) do
    {:msg, :submit}
  end

  def event_to_msg(%Event.Key{code: "up"} = event, state) do
    if command_menu_visible?(state), do: {:msg, {:move_command, -1}}, else: input_msg(event)
  end

  def event_to_msg(%Event.Key{code: "down"} = event, state) do
    if command_menu_visible?(state), do: {:msg, {:move_command, 1}}, else: input_msg(event)
  end

  def event_to_msg(%Event.Key{code: "tab"} = event, state) do
    if command_menu_visible?(state), do: {:msg, :complete_command}, else: input_msg(event)
  end

  def event_to_msg(%Event.Key{code: "esc"}, state) do
    if command_menu_visible?(state), do: {:msg, :close_command_menu}, else: {:msg, :close_panel}
  end

  def event_to_msg(event, _state) do
    {:msg, {:input_event, event}}
  end

  @doc """
  Applies one internal UI message to root state.
  """
  @spec reduce(term(), t()) :: {t(), [atom()]}
  def reduce({:resize, width, height}, state) do
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

  def reduce({:set_submit_prompt, submit_prompt}, state) when is_function(submit_prompt, 1) do
    {%{state | submit_prompt: submit_prompt}, []}
  end

  def reduce({:submit_initial, prompt}, state) do
    {submit_prompt(state, prompt), []}
  end

  def reduce({:agent_event, event}, state) do
    state =
      %{
        state
        | status: Status.reduce_event(state.status, event),
          transcript: Transcript.append_event(state.transcript, event)
      }

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
    input = Prompt.handle_event(state.input, event)
    prompt = Prompt.value(input)
    selected_command = CommandMenu.clamp_index(state.selected_command, prompt)

    {%{state | input: input, selected_command: selected_command}, []}
  end

  def reduce(:quit, state), do: {state, [:quit]}
  def reduce(_msg, state), do: {state, []}

  @impl true
  def render(state, frame) do
    scene(state, frame)
  end

  @doc """
  Renders the current state into ExRatatui widgets.
  """
  @spec scene(t(), Frame.t()) :: [{ExRatatui.widget(), Rect.t()}]
  def scene(state, %Frame{} = frame) do
    width = max(1, frame.width)
    height = max(1, frame.height)
    layout = layout(state, width, height)

    []
    |> add_line("Elixir Agent", layout.header, style(:cyan, [:bold]))
    |> add_line(Status.summary_line(state.status), layout.status, style(:dark_gray))
    |> add_line(divider(width), layout.top_divider, style(:dark_gray))
    |> add_lines(
      transcript_lines(state, layout.transcript.width, layout.transcript.height),
      layout.transcript,
      %Style{}
    )
    |> add_line(divider(width), layout.bottom_divider, style(:dark_gray))
    |> add_lines(panel_lines(state, width), layout.panel, style(:yellow, [:bold]))
    |> add_lines(command_lines(state, width), layout.commands, style(:yellow, [:bold]))
    |> add_prompt(state.input, layout.prompt)
    |> add_line(footer_line(state), layout.footer, style(:dark_gray))
    |> Enum.reverse()
  end

  @doc false
  @spec view(t()) :: [{ExRatatui.widget(), Rect.t()}]
  def view(state) do
    scene(state, %Frame{width: state.width, height: state.height})
  end

  defp apply_msg({:msg, msg}, state) do
    msg
    |> reduce(state)
    |> callback_result()
  end

  defp callback_result({state, actions}) do
    if :quit in actions, do: {:stop, state}, else: {:noreply, state}
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

  defp ctrl?(modifiers), do: "ctrl" in modifiers or :ctrl in modifiers

  defp input_msg(event), do: {:msg, {:input_event, event}}

  defp layout(state, width, height) do
    prompt_height = min(state.input.max_visible_lines, max(1, height - 5))
    remaining = max(1, height - prompt_height - 5)

    desired_panel_height = state |> panel_lines(width) |> desired_height(6)
    panel_height = min(desired_panel_height, max(0, remaining - 1))
    remaining = remaining - panel_height

    desired_command_height = state |> command_lines(width) |> desired_height(7)
    command_height = min(desired_command_height, max(0, remaining - 1))
    transcript_height = max(1, remaining - command_height)

    y = 0
    header = rect(width, y, 1)
    status = rect(width, y + 1, 1)
    top_divider = rect(width, y + 2, 1)
    transcript = rect(width, y + 3, transcript_height)
    bottom_divider = rect(width, transcript.y + transcript.height, 1)
    panel = rect(width, bottom_divider.y + 1, panel_height)
    commands = rect(width, panel.y + panel.height, command_height)
    prompt = rect(width, commands.y + commands.height, prompt_height)
    footer = rect(width, prompt.y + prompt.height, 1)

    %{
      bottom_divider: bottom_divider,
      commands: commands,
      footer: footer,
      header: header,
      panel: panel,
      prompt: prompt,
      status: status,
      top_divider: top_divider,
      transcript: transcript
    }
  end

  defp add_line(widgets, line, rect, style) do
    add_lines(widgets, [fit_line(line, rect.width)], rect, style)
  end

  defp add_lines(widgets, _lines, %{height: 0}, _style), do: widgets

  defp add_lines(widgets, lines, rect, style) do
    text =
      lines
      |> Enum.take(rect.height)
      |> Enum.map(&fit_line(&1, rect.width))
      |> Enum.join("\n")

    add_widget(widgets, %Paragraph{text: text, style: style}, rect)
  end

  defp add_prompt(widgets, input, %{width: width, height: height} = rect)
       when width > 2 and height > 0 do
    prefix_rect = %{rect | width: 2}
    input_rect = %{rect | x: rect.x + 2, width: width - 2}

    widgets
    |> add_widget(%Paragraph{text: "> ", style: style(:green, [:bold])}, prefix_rect)
    |> add_widget(Prompt.render(input), input_rect)
  end

  defp add_prompt(widgets, _input, _rect), do: widgets

  defp add_widget(widgets, _widget, %{width: width}) when width <= 0, do: widgets
  defp add_widget(widgets, _widget, %{height: height}) when height <= 0, do: widgets
  defp add_widget(widgets, widget, rect), do: [{widget, rect} | widgets]

  defp transcript_lines(state, width, height) do
    state.transcript
    |> Transcript.visible_lines(width, height)
    |> fill_lines(height)
  end

  defp panel_lines(%{panel: nil}, _width), do: []

  defp panel_lines(%{panel: :help}, width) do
    titled_lines("commands", CommandMenu.help_lines(), width)
  end

  defp panel_lines(%{panel: :status} = state, width) do
    titled_lines("status", Status.panel_lines(state.status), width)
  end

  defp command_lines(state, width) do
    prompt = Prompt.value(state.input)

    prompt
    |> CommandMenu.lines(state.selected_command, width)
    |> Enum.take(6)
    |> case do
      [] -> []
      lines -> titled_lines("commands", lines, width)
    end
  end

  defp footer_line(state) do
    state.notice ||
      if MapSet.size(state.pending_prompts) > 0 do
        "running..."
      else
        "Enter send | /status | /help | Ctrl+C quit"
      end
  end

  defp titled_lines(title, lines, width) do
    [
      fit_line("[#{title}]", width)
      | Enum.map(lines, &fit_line(&1, width))
    ]
  end

  defp desired_height([], _limit), do: 0
  defp desired_height(lines, limit), do: min(length(lines), limit)

  defp fill_lines(lines, height) do
    padding = max(0, height - length(lines))
    List.duplicate("", padding) ++ lines
  end

  defp divider(width) do
    String.duplicate("-", max(1, width))
  end

  defp rect(width, y, height) do
    %Rect{x: 0, y: y, width: width, height: height}
  end

  defp prompt_width(width), do: max(10, width - 2)

  defp fit_line(line, width) when is_binary(line) do
    line
    |> String.graphemes()
    |> Enum.take(max(1, width))
    |> Enum.join()
  end

  defp style(color, modifiers \\ []) do
    %Style{fg: color, modifiers: modifiers}
  end

  defp result_notice({:ok, _reply}), do: nil
  defp result_notice({:error, reason}), do: format_error("prompt", reason)
  defp result_notice(result), do: format_error("prompt", result)

  defp format_error(scope, reason) do
    "#{scope} failed: #{inspect(reason)}"
  end
end
