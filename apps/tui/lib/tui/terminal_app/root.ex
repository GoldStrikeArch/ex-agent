defmodule Tui.TerminalApp.Root do
  @moduledoc """
  ExRatatui root application for the agent terminal UI.

  Root keeps the TermUI lifecycle boundary: it translates terminal events into
  internal messages, delegates state transitions to `Tui.TerminalApp.State`,
  and composes render components into screen regions.
  """

  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Frame
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Subscription
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Scrollbar
  alias Tui.Components.CommandPalette
  alias Tui.Components.Footer
  alias Tui.Components.Panel
  alias Tui.Components.PromptBar
  alias Tui.Components.StatusBar
  alias Tui.Components.Text
  alias Tui.Components.Transcript
  alias Tui.TerminalApp.Prompt
  alias Tui.TerminalApp.State

  @type t :: State.t()

  # Lines scrolled per mouse-wheel notch.
  @mouse_scroll_step 3

  # Spinner animation cadence while tools are running.
  @spinner_interval_ms 100

  @doc """
  Builds the initial root state.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: State.new(opts)

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

  def event_to_msg(%Event.Key{code: "enter", modifiers: modifiers}, _state) do
    if newline_modifier?(modifiers), do: {:msg, :insert_newline}, else: {:msg, :submit}
  end

  def event_to_msg(%Event.Key{code: "j", modifiers: modifiers} = event, _state) do
    if ctrl?(modifiers), do: {:msg, :insert_newline}, else: input_msg(event)
  end

  def event_to_msg(%Event.Key{code: "l", modifiers: modifiers} = event, _state) do
    if ctrl?(modifiers), do: {:msg, :clear_transcript}, else: input_msg(event)
  end

  def event_to_msg(%Event.Key{code: code} = _event, state)
      when code in ~w(page_up page_down home end) do
    {:msg, {:scroll, scroll_direction(code), transcript_height(state)}}
  end

  def event_to_msg(%Event.Mouse{kind: "scroll_up"}, state) do
    {:msg, {:scroll, {:lines, -@mouse_scroll_step}, transcript_height(state)}}
  end

  def event_to_msg(%Event.Mouse{kind: "scroll_down"}, state) do
    {:msg, {:scroll, {:lines, @mouse_scroll_step}, transcript_height(state)}}
  end

  def event_to_msg(%Event.Key{code: "up"} = event, state) do
    if State.command_menu_visible?(state),
      do: {:msg, {:move_command, -1}},
      else: {:msg, {:history_prev, event}}
  end

  def event_to_msg(%Event.Key{code: "down"} = event, state) do
    if State.command_menu_visible?(state),
      do: {:msg, {:move_command, 1}},
      else: {:msg, {:history_next, event}}
  end

  def event_to_msg(%Event.Key{code: "tab"} = event, state) do
    if State.command_menu_visible?(state), do: {:msg, :complete_command}, else: input_msg(event)
  end

  def event_to_msg(%Event.Key{code: "esc"}, state) do
    if State.command_menu_visible?(state),
      do: {:msg, :close_command_menu},
      else: {:msg, :close_panel}
  end

  def event_to_msg(event, _state) do
    {:msg, {:input_event, event}}
  end

  @doc """
  Applies one internal UI message to root state.
  """
  @spec reduce(term(), t()) :: {t(), [atom()]}
  def reduce(msg, state), do: State.reduce(msg, state)

  @impl true
  def render(state, frame) do
    scene(state, frame)
  end

  @impl true
  def subscriptions(state) do
    if State.running?(state) do
      [Subscription.interval(:spinner, @spinner_interval_ms, :spinner_tick)]
    else
      []
    end
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
    |> add_line("Elixir Agent", layout.header, %Style{fg: :cyan, modifiers: [:bold]})
    |> add_widget(StatusBar.render(state.status, width), layout.status)
    |> add_line(Text.divider(width), layout.top_divider, %Style{fg: :dark_gray})
    |> add_widget(
      Transcript.render(
        state.transcript,
        Transcript.content_width(layout.transcript.width),
        layout.transcript.height,
        Transcript.spinner_glyph(state.spinner)
      ),
      layout.transcript
    )
    |> add_scrollbar(state.transcript, layout.transcript)
    |> add_line(Text.divider(width), layout.bottom_divider, %Style{fg: :dark_gray})
    |> add_widget(Panel.render(state.panel, state.status, width), layout.panel)
    |> add_widget(command_palette(state, width), layout.commands)
    |> add_widgets(PromptBar.render(state.input, layout.prompt))
    |> add_widget(Footer.render(state, width), layout.footer)
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
    cond do
      :quit in actions ->
        {:stop, state}

      # Suppress the per-message re-render for high-frequency streaming events;
      # the 100ms spinner tick coalesces paints to ~10fps. Capped render cadence
      # keeps long streams from spending O(N) per-delta render time × N deltas.
      :skip_render in actions ->
        {:noreply, state, render?: false}

      true ->
        {:noreply, state}
    end
  end

  defp ctrl?(modifiers), do: "ctrl" in modifiers or :ctrl in modifiers

  defp newline_modifier?(modifiers) do
    Enum.any?(~w(shift alt meta super hyper), &(&1 in modifiers)) or
      Enum.any?([:shift, :alt, :meta, :super, :hyper], &(&1 in modifiers))
  end

  defp scroll_direction("page_up"), do: :page_up
  defp scroll_direction("page_down"), do: :page_down
  defp scroll_direction("home"), do: :top
  defp scroll_direction("end"), do: :bottom

  defp transcript_height(state) do
    layout(state, state.width, state.height).transcript.height
  end

  defp input_msg(event), do: {:msg, {:input_event, event}}

  defp layout(state, width, height) do
    prompt_height = min(state.input.max_visible_lines, max(1, height - 5))
    remaining = max(1, height - prompt_height - 5)

    desired_panel_height = state.panel |> Panel.lines(state.status, width) |> desired_height(6)
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

  defp command_palette(state, width) do
    state.input
    |> Prompt.value()
    |> CommandPalette.render(state.selected_command, width)
  end

  defp command_lines(state, width) do
    state.input
    |> Prompt.value()
    |> CommandPalette.lines(state.selected_command, width)
  end

  defp add_scrollbar(widgets, transcript, %Rect{} = rect)
       when rect.width > 1 and rect.height > 0 do
    metrics =
      Transcript.viewport_metrics(transcript, Transcript.content_width(rect.width), rect.height)

    # ratatui normalizes the thumb by `position / content_length` and uses
    # `viewport_content_length` only for thumb size, so drive the bar with the
    # scrollable range (total - viewport). That maps a top position of 0 to the
    # track top and the bottom position to the track bottom.
    scrollable = metrics.content_length - metrics.viewport

    if scrollable > 0 do
      scrollbar = %Scrollbar{
        orientation: :vertical_right,
        content_length: scrollable,
        position: min(metrics.position, scrollable)
      }

      bar_rect = %Rect{x: rect.x + rect.width - 1, y: rect.y, width: 1, height: rect.height}
      add_widget(widgets, scrollbar, bar_rect)
    else
      widgets
    end
  end

  defp add_scrollbar(widgets, _transcript, _rect), do: widgets

  defp add_line(widgets, line, rect, style) do
    add_widget(widgets, Text.paragraph([Text.fit_line(line, rect.width)], style), rect)
  end

  defp add_widgets(widgets, rendered) do
    Enum.reduce(rendered, widgets, fn {widget, rect}, acc ->
      add_widget(acc, widget, rect)
    end)
  end

  defp add_widget(widgets, _widget, %{width: width}) when width <= 0, do: widgets
  defp add_widget(widgets, _widget, %{height: height}) when height <= 0, do: widgets
  defp add_widget(widgets, %Paragraph{text: ""}, _rect), do: widgets
  defp add_widget(widgets, widget, rect), do: [{widget, rect} | widgets]

  defp desired_height([], _limit), do: 0
  defp desired_height(lines, limit), do: min(length(lines), limit)

  defp rect(width, y, height) do
    %Rect{x: 0, y: y, width: width, height: height}
  end
end
