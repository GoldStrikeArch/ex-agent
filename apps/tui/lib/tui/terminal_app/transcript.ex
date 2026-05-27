defmodule Tui.TerminalApp.Transcript do
  @moduledoc """
  Maintains structured transcript blocks for the interactive terminal UI.

  `Tui.TextRenderer` remains the canonical append-only text renderer for
  replay and logs. This module keeps live UI state rich enough to update active
  assistant messages, tools, permissions, and edit previews in place.
  """

  alias Tui.Transcript.Block

  # Column reserved on the right for the scrollbar. Reserved unconditionally so
  # the layout does not reflow when the scrollbar appears or disappears.
  @scrollbar_gutter 1

  defstruct active_messages: %{},
            active_permissions: MapSet.new(),
            active_tools: %{},
            anchor: nil,
            blocks: [],
            follow?: true,
            max_blocks: 250

  @type tool_state :: %{
          name: String.t(),
          args: map(),
          output_bytes: non_neg_integer(),
          started_at: integer() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @typedoc """
  A stable scroll anchor: the block whose `line`-th wrapped line sits at the top
  of the viewport. Anchoring on block identity (rather than an absolute line
  index) keeps the view fixed while blocks stream above it or evict off the top.
  """
  @type anchor :: %{block_id: String.t(), line: non_neg_integer()} | nil

  @type t :: %__MODULE__{
          active_messages: %{String.t() => atom()},
          active_permissions: term(),
          active_tools: %{String.t() => tool_state()},
          anchor: anchor(),
          blocks: [Block.t()],
          follow?: boolean(),
          max_blocks: pos_integer()
        }

  @type scroll_direction :: :page_up | :page_down | :top | :bottom | {:lines, integer()}

  @typedoc "Style category attached to each rendered line for per-block colorizing."
  @type style_tag ::
          :blank
          | :system
          | :label
          | :user
          | :assistant
          | :tool_header
          | :tool_body
          | :permission
          | :error
          | :edit
          | :diff_add
          | :diff_del
          | :diff_hunk
          | :diff_context

  @typedoc "A viewport line paired with the style category used to render it."
  @type styled_line :: {style_tag(), String.t()}

  @doc """
  Builds an empty transcript.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_blocks = opts |> Keyword.get(:max_blocks, 250) |> positive_integer_or(250)
    %__MODULE__{max_blocks: max_blocks}
  end

  @doc """
  Width available for transcript text after reserving the scrollbar gutter.

  Callers wrap and measure content against this width so a full-width line never
  collides with the scrollbar drawn in the last column, and so the view stays
  stable whether or not the scrollbar is currently shown.
  """
  @spec content_width(pos_integer()) :: pos_integer()
  def content_width(total_width) when is_integer(total_width) and total_width > 0 do
    max(1, total_width - @scrollbar_gutter)
  end

  @doc """
  Appends one agent event to the transcript.
  """
  @spec append_event(t(), tuple()) :: t()
  def append_event(%__MODULE__{} = transcript, {:session_started, %{session_id: session_id}}) do
    append_block(transcript, system_block("session started #{session_id}"))
  end

  def append_event(%__MODULE__{} = transcript, {:user_message, text}) when is_binary(text) do
    append_block(transcript, block(unique_id("user"), :user, :done, "user", [text]))
  end

  def append_event(%__MODULE__{} = transcript, {:message_started, message_id, :assistant}) do
    start_message(transcript, message_id, :assistant)
  end

  def append_event(%__MODULE__{} = transcript, {:message_started, message_id, role})
      when role in [:system, :permission] do
    start_message(transcript, message_id, role)
  end

  def append_event(%__MODULE__{} = transcript, {:message_started, _message_id, _role}) do
    transcript
  end

  def append_event(%__MODULE__{} = transcript, {:message_delta, message_id, text})
      when is_binary(text) do
    append_message_delta(transcript, message_id, text)
  end

  def append_event(%__MODULE__{} = transcript, {:message_finished, %{role: :tool} = message}) do
    maybe_append_tool_message(transcript, message)
  end

  def append_event(%__MODULE__{} = transcript, {:message_finished, %{role: role} = message}) do
    finish_message(transcript, message_id(message), role, message_content(message))
  end

  def append_event(%__MODULE__{} = transcript, {:assistant_message_started, message_id}) do
    start_message(transcript, message_id, :assistant)
  end

  def append_event(%__MODULE__{} = transcript, {:assistant_delta, message_id, text})
      when is_binary(text) do
    append_message_delta(transcript, message_id, text)
  end

  def append_event(%__MODULE__{} = transcript, {:assistant_message_finished, message_id}) do
    finish_message(transcript, message_id, :assistant, "")
  end

  def append_event(%__MODULE__{} = transcript, {:tool_started, call_id, name, args}) do
    do_tool_started(transcript, call_id, name, args, nil)
  end

  def append_event(%__MODULE__{} = transcript, {:tool_output, call_id, chunk})
      when is_binary(chunk) do
    call_id = to_string(call_id)
    tool = Map.get(transcript.active_tools, call_id, default_tool(call_id))
    tool = Map.update!(tool, :output_bytes, &(&1 + byte_size(chunk)))

    transcript
    |> Map.update!(:active_tools, &Map.put(&1, call_id, tool))
    |> replace_block(call_id, tool_block(call_id, tool, :streaming, "running"))
  end

  def append_event(%__MODULE__{} = transcript, {:tool_finished, call_id, status, summary}) do
    do_tool_finished(transcript, call_id, status, summary, nil)
  end

  def append_event(%__MODULE__{} = transcript, {:batch_started, batch_id, count}) do
    append_block(transcript, system_block("batch #{batch_id} started #{count} calls"))
  end

  def append_event(%__MODULE__{} = transcript, {:batch_finished, batch_id, status}) do
    append_block(transcript, system_block("batch #{batch_id} finished #{inspect(status)}"))
  end

  def append_event(%__MODULE__{} = transcript, {:edit_preview, edit_id, file_path, diff}) do
    edit_id = to_string(edit_id)
    append_block(transcript, block(edit_id, :edit, :done, "edit preview #{file_path}", [diff]))
  end

  def append_event(%__MODULE__{} = transcript, {:edit_applied, edit_id, file_path}) do
    edit_id = to_string(edit_id)
    append_block(transcript, block(edit_id, :edit, :done, "edit applied #{file_path}", []))
  end

  def append_event(%__MODULE__{} = transcript, {:validation_started, command}) do
    append_block(transcript, system_block("validation #{command} started"))
  end

  def append_event(
        %__MODULE__{} = transcript,
        {:validation_finished, command, exit_status, summary}
      ) do
    append_block(
      transcript,
      system_block("validation #{command} finished #{exit_status} #{summary}")
    )
  end

  def append_event(%__MODULE__{} = transcript, {:permission_requested, request_id, action}) do
    request_id = to_string(request_id)

    permission =
      block(request_id, :permission, :streaming, "permission requested", [inspect(action)])

    transcript
    |> Map.update!(:active_permissions, &MapSet.put(&1, request_id))
    |> append_block(permission)
  end

  def append_event(%__MODULE__{} = transcript, {:permission_resolved, request_id, decision}) do
    request_id = to_string(request_id)
    permission = block(request_id, :permission, :done, "permission resolved", [inspect(decision)])

    transcript
    |> Map.update!(:active_permissions, &MapSet.delete(&1, request_id))
    |> replace_or_append_block(request_id, permission)
  end

  def append_event(%__MODULE__{} = transcript, {:error, scope, reason}) do
    append_block(
      transcript,
      block(unique_id("error"), :error, :error, "error #{inspect(scope)}", [inspect(reason)])
    )
  end

  def append_event(%__MODULE__{} = transcript, event) do
    append_block(transcript, system_block(inspect(event)))
  end

  @doc """
  Appends one agent event tagged with the time it was received.

  `now_ms` is a monotonic millisecond reading taken at the edge (the UI reducer).
  Passing it in lets tool blocks report their duration without this module
  reading the clock, so the fold stays pure and deterministic. `append_event/2`
  is `append_event/3` with no timestamp, in which case no timing is shown.
  """
  @spec append_event(t(), tuple(), integer() | nil) :: t()
  def append_event(%__MODULE__{} = transcript, {:tool_started, call_id, name, args}, now_ms) do
    do_tool_started(transcript, call_id, name, args, now_ms)
  end

  def append_event(
        %__MODULE__{} = transcript,
        {:tool_finished, call_id, status, summary},
        now_ms
      ) do
    do_tool_finished(transcript, call_id, status, summary, now_ms)
  end

  def append_event(%__MODULE__{} = transcript, event, _now_ms) do
    append_event(transcript, event)
  end

  @doc """
  Appends already-rendered text as a system transcript block.
  """
  @spec append_text(String.t(), t()) :: t()
  def append_text("", %__MODULE__{} = transcript), do: transcript

  def append_text(text, %__MODULE__{} = transcript) when is_binary(text) do
    text
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.reduce(transcript, fn line, acc -> append_block(acc, system_block(line)) end)
  end

  @doc """
  Returns viewport-ready transcript lines for the current scroll position.

  While following (the default), the most recent `height` lines are shown and
  new content keeps the viewport pinned to the bottom. When the user has
  scrolled up, the view stays anchored at `top` so streaming appends do not move
  it.
  """
  @spec visible_lines(t(), pos_integer(), pos_integer()) :: [String.t()]
  def visible_lines(%__MODULE__{} = transcript, width, height) do
    transcript
    |> visible_styled_lines(width, height)
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Returns viewport-ready lines tagged with their style category.

  Uses the same viewport math as `visible_lines/3`, but keeps the style tag
  derived from each line's source block so renderers can colorize per block kind
  (assistant text, tool output, errors, and so on).
  """
  @spec visible_styled_lines(t(), pos_integer(), pos_integer()) :: [styled_line()]
  def visible_styled_lines(%__MODULE__{} = transcript, width, height) do
    visible_styled_lines(transcript, width, height, "")
  end

  @doc """
  Like `visible_styled_lines/3`, but prefixes running tool headers with `spinner`.

  `spinner` is the current animation glyph (a string), supplied by the renderer.
  It is baked into the header text before wrapping so width accounting stays
  correct; passing `""` shows no spinner.
  """
  @spec visible_styled_lines(t(), pos_integer(), pos_integer(), String.t()) :: [styled_line()]
  def visible_styled_lines(%__MODULE__{} = transcript, width, height, spinner)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    segments = segments(transcript, width, spinner)
    lines = flat_lines(segments)
    top = top_index(transcript, segments, length(lines), height)

    lines
    |> Enum.drop(top)
    |> Enum.take(height)
  end

  def visible_styled_lines(%__MODULE__{}, _width, _height, _spinner), do: []

  @doc """
  Returns true while at least one tool is still running.
  """
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{active_tools: active_tools}), do: active_tools != %{}

  @doc """
  Scrolls the viewport. Reaching the bottom re-enables auto-follow.

  `{:lines, n}` scrolls by `n` lines (negative scrolls up); `:page_up` /
  `:page_down` move by a viewport height; `:top` / `:bottom` jump to the ends.
  """
  @spec scroll(t(), scroll_direction(), pos_integer(), pos_integer()) :: t()
  def scroll(%__MODULE__{} = transcript, direction, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    segments = segments(transcript, width, "")
    total = segments |> flat_lines() |> length()
    max_top = max(0, total - height)
    current = top_index(transcript, segments, total, height)

    top =
      direction
      |> next_top(current, max_top, height)
      |> max(0)
      |> min(max_top)

    if top >= max_top do
      %{transcript | follow?: true, anchor: nil}
    else
      %{transcript | follow?: false, anchor: index_anchor(segments, top)}
    end
  end

  def scroll(%__MODULE__{} = transcript, _direction, _width, _height), do: transcript

  @doc """
  Returns scroll metrics for rendering a position indicator.

  `position` is the top visible line index, `content_length` the total wrapped
  line count, and `viewport` the visible height.
  """
  @spec viewport_metrics(t(), pos_integer(), pos_integer()) :: %{
          content_length: non_neg_integer(),
          position: non_neg_integer(),
          viewport: pos_integer()
        }
  def viewport_metrics(%__MODULE__{} = transcript, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    segments = segments(transcript, width, "")
    total = segments |> flat_lines() |> length()

    %{
      content_length: total,
      position: top_index(transcript, segments, total, height),
      viewport: height
    }
  end

  def viewport_metrics(%__MODULE__{}, _width, _height) do
    %{content_length: 0, position: 0, viewport: 1}
  end

  @doc """
  Clears the transcript.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = transcript) do
    %{
      transcript
      | active_messages: %{},
        active_permissions: MapSet.new(),
        active_tools: %{},
        anchor: nil,
        blocks: [],
        follow?: true
    }
  end

  @doc """
  Returns blocks in display order.
  """
  @spec blocks(t()) :: [Block.t()]
  def blocks(%__MODULE__{} = transcript), do: Enum.reverse(transcript.blocks)

  defp start_message(transcript, message_id, role) do
    message_id = to_string(message_id)
    kind = block_kind(role)

    transcript
    |> Map.update!(:active_messages, &Map.put(&1, message_id, role))
    |> append_block(block(message_id, kind, :streaming, Atom.to_string(role), []))
  end

  defp append_message_delta(transcript, message_id, text) do
    message_id = to_string(message_id)

    case Map.fetch(transcript.active_messages, message_id) do
      {:ok, _role} ->
        update_block(transcript, message_id, &append_body_text(&1, text))

      :error ->
        transcript
        |> start_message(message_id, :assistant)
        |> update_block(message_id, &append_body_text(&1, text))
    end
  end

  defp finish_message(transcript, message_id, role, content) do
    message_id = to_string(message_id)
    kind = block_kind(role)
    active? = Map.has_key?(transcript.active_messages, message_id)

    transcript =
      transcript
      |> Map.update!(:active_messages, &Map.delete(&1, message_id))

    if active? do
      update_block(transcript, message_id, &finish_block(&1, content))
    else
      append_block(
        transcript,
        block(message_id, kind, :done, Atom.to_string(role), body_from_content(content))
      )
    end
  end

  defp maybe_append_tool_message(transcript, message) do
    tool_call_id = Map.get(message, :tool_call_id, Map.get(message, "tool_call_id"))

    if tool_call_id && block_exists?(transcript, tool_call_id) do
      transcript
    else
      finish_message(transcript, message_id(message), :tool, message_content(message))
    end
  end

  defp append_block(transcript, %Block{} = block) do
    blocks =
      [block | transcript.blocks]
      |> Enum.take(transcript.max_blocks)

    %{transcript | blocks: blocks}
  end

  defp replace_block(transcript, id, %Block{} = replacement) do
    update_block(transcript, id, fn _block -> replacement end)
  end

  defp replace_or_append_block(transcript, id, %Block{} = replacement) do
    if block_exists?(transcript, id) do
      replace_block(transcript, id, replacement)
    else
      append_block(transcript, replacement)
    end
  end

  defp update_block(transcript, id, fun) when is_function(fun, 1) do
    id = to_string(id)

    blocks =
      Enum.map(transcript.blocks, fn
        %Block{id: ^id} = block -> fun.(block)
        block -> block
      end)

    %{transcript | blocks: blocks}
  end

  defp block_exists?(transcript, id) do
    id = to_string(id)
    Enum.any?(transcript.blocks, &(&1.id == id))
  end

  defp append_body_text(%Block{} = block, text) do
    %{block | body: [body_text(block) <> text]}
  end

  defp finish_block(%Block{} = block, "") do
    %{block | status: :done}
  end

  defp finish_block(%Block{body: []} = block, content) do
    %{block | status: :done, body: body_from_content(content)}
  end

  defp finish_block(%Block{} = block, _content) do
    %{block | status: :done}
  end

  defp tool_block(call_id, tool, status, summary) do
    body =
      [summary_line(summary), bytes_line(tool), timing_line(tool), args_line(tool.args)]
      |> Enum.reject(&(&1 == ""))

    block(call_id, :tool, status, tool_title(tool), body)
  end

  defp do_tool_started(transcript, call_id, name, args, now_ms) do
    call_id = to_string(call_id)
    tool = %{default_tool(name) | args: args, started_at: now_ms}

    transcript
    |> Map.update!(:active_tools, &Map.put(&1, call_id, tool))
    |> append_block(tool_block(call_id, tool, :streaming, "running"))
  end

  defp do_tool_finished(transcript, call_id, status, summary, now_ms) do
    call_id = to_string(call_id)
    {tool, active_tools} = Map.pop(transcript.active_tools, call_id)
    tool = tool || default_tool(call_id)
    tool = Map.put(tool, :duration_ms, duration(tool, now_ms))

    transcript
    |> Map.put(:active_tools, active_tools)
    |> replace_or_append_block(
      call_id,
      tool_block(call_id, tool, block_status(status), format_summary(summary))
    )
  end

  defp default_tool(name) do
    %{name: to_string(name), args: %{}, output_bytes: 0, started_at: nil, duration_ms: nil}
  end

  defp duration(%{started_at: started}, now) when is_integer(started) and is_integer(now) do
    max(0, now - started)
  end

  defp duration(_tool, _now), do: nil

  # A tool reads as `name target`, e.g. `read_file mix.exs`, mirroring Pi.
  defp tool_title(tool) do
    [tool.name, tool_target(tool.args)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  @tool_target_keys [
    "path",
    :path,
    "file_path",
    :file_path,
    "file",
    :file,
    "command",
    :command,
    "pattern",
    :pattern
  ]

  defp tool_target(args) when is_map(args) do
    @tool_target_keys
    |> Enum.find_value("", fn key ->
      case Map.fetch(args, key) do
        {:ok, value} when is_binary(value) -> first_line(value)
        _ -> nil
      end
    end)
  end

  defp tool_target(_args), do: ""

  defp first_line(value), do: value |> String.split("\n", parts: 2) |> hd()

  defp bytes_line(%{output_bytes: 0}), do: ""
  defp bytes_line(%{output_bytes: bytes}), do: "output #{bytes} B"

  defp timing_line(%{duration_ms: ms}) when is_integer(ms), do: "Took #{format_duration(ms)}"
  defp timing_line(_tool), do: ""

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  defp block(id, kind, status, title, body) do
    %Block{
      id: to_string(id),
      kind: kind,
      status: status,
      title: title,
      body: Enum.map(body, &to_string/1)
    }
  end

  defp system_block(title), do: block(unique_id("system"), :system, :done, title, [])

  defp body_text(%Block{body: body}) do
    Enum.join(body)
  end

  defp body_from_content(content) when is_binary(content) and content != "", do: [content]
  defp body_from_content(_content), do: []

  defp block_kind(:user), do: :user
  defp block_kind(:assistant), do: :assistant
  defp block_kind(:tool), do: :tool
  defp block_kind(:permission), do: :permission
  defp block_kind(:system), do: :system
  defp block_kind(_role), do: :system

  defp block_status(:ok), do: :done
  defp block_status(:done), do: :done
  defp block_status(_status), do: :error

  defp message_id(%{id: id}), do: to_string(id)
  defp message_id(%{"id" => id}), do: to_string(id)
  defp message_id(_message), do: unique_id("message")

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(%{"content" => content}) when is_binary(content), do: content
  defp message_content(_message), do: ""

  defp format_summary(summary) when is_binary(summary), do: summary
  defp format_summary(summary), do: inspect(summary)

  defp summary_line(""), do: ""
  defp summary_line("running"), do: ""
  defp summary_line(summary), do: "summary #{summary}"

  defp args_line(args) when args == %{}, do: ""
  defp args_line(args), do: "args #{inspect(args)}"

  defp segments(transcript, width, spinner) do
    {segments, _prev_kind} =
      transcript.blocks
      |> Enum.reverse()
      |> Enum.map_reduce(nil, fn %Block{id: id, kind: kind} = block, prev_kind ->
        lines = spacer(kind, prev_kind) ++ block_lines(block, width, spinner)
        {{id, lines}, kind}
      end)

    segments
  end

  # Separate adjacent blocks with a blank line only when the kind changes, so
  # turns and roles get breathing room without splitting runs of same-kind lines.
  defp spacer(_kind, nil), do: []
  defp spacer(kind, kind), do: []
  defp spacer(_kind, _prev_kind), do: [{:blank, ""}]

  defp flat_lines(segments) do
    Enum.flat_map(segments, fn {_id, lines} -> lines end)
  end

  defp top_index(%__MODULE__{follow?: true}, _segments, total, height) do
    max(0, total - height)
  end

  defp top_index(%__MODULE__{anchor: anchor}, segments, total, height) do
    anchor
    |> anchor_index(segments)
    |> clamp_top(total, height)
  end

  defp clamp_top(top, total, height) do
    top
    |> max(0)
    |> min(max(0, total - height))
  end

  defp anchor_index(nil, _segments), do: 0

  defp anchor_index(%{block_id: id, line: line}, segments) do
    anchor_index(segments, id, line, 0)
  end

  defp anchor_index([], _id, _line, _acc), do: 0

  defp anchor_index([{id, lines} | _rest], id, line, acc) do
    acc + min(max(0, line), max(0, length(lines) - 1))
  end

  defp anchor_index([{_other, lines} | rest], id, line, acc) do
    anchor_index(rest, id, line, acc + length(lines))
  end

  defp index_anchor([], _index), do: nil

  defp index_anchor([{id, lines} | rest], index) do
    count = length(lines)

    if index < count do
      %{block_id: id, line: max(0, index)}
    else
      index_anchor(rest, index - count)
    end
  end

  defp next_top(:page_up, current, _max_top, height), do: current - height
  defp next_top(:page_down, current, _max_top, height), do: current + height
  defp next_top(:top, _current, _max_top, _height), do: 0
  defp next_top(:bottom, _current, max_top, _height), do: max_top
  defp next_top({:lines, n}, current, _max_top, _height), do: current + n

  defp block_lines(%Block{kind: :system, body: []} = block, width, _spinner) do
    block.title |> wrap_line(width) |> tag_lines(:system)
  end

  defp block_lines(%Block{kind: :user} = block, width, _spinner) do
    block
    |> body_text()
    |> then(&["user> " <> &1])
    |> wrap_lines(width)
    |> tag_lines(:user)
  end

  defp block_lines(%Block{} = block, width, spinner) do
    header_tag = header_tag(block.kind, block.status)
    header = block |> block_header(spinner) |> wrap_line(width) |> tag_lines(header_tag)
    body = Enum.flat_map(block.body, &body_lines_for(block.kind, &1, width))
    header ++ body
  end

  defp tag_lines(lines, tag), do: Enum.map(lines, &{tag, &1})

  # A failed tool keeps the error color so the header reads as red, not green.
  defp header_tag(:tool, :error), do: :error
  defp header_tag(:tool, _status), do: :tool_header
  defp header_tag(:permission, _status), do: :permission
  defp header_tag(:error, _status), do: :error
  defp header_tag(:edit, _status), do: :edit
  defp header_tag(_kind, _status), do: :label

  defp body_lines_for(:edit, text, width), do: diff_body_lines(text, width)

  defp body_lines_for(kind, text, width) do
    text |> body_lines(width) |> tag_lines(body_tag(kind))
  end

  # Tag each physical diff line by its prefix so additions, deletions, and hunk
  # headers colorize independently within one edit block.
  defp diff_body_lines(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      ("  " <> line) |> wrap_line(width) |> tag_lines(diff_tag(line))
    end)
  end

  defp diff_tag("+++" <> _), do: :diff_hunk
  defp diff_tag("---" <> _), do: :diff_hunk
  defp diff_tag("@@" <> _), do: :diff_hunk
  defp diff_tag("+" <> _), do: :diff_add
  defp diff_tag("-" <> _), do: :diff_del
  defp diff_tag(_line), do: :diff_context

  defp body_tag(:assistant), do: :assistant
  defp body_tag(:tool), do: :tool_body
  defp body_tag(:permission), do: :permission
  defp body_tag(:error), do: :error
  defp body_tag(_kind), do: :system

  # A running tool shows an animated spinner in place of a "[running]" label;
  # finished and non-tool blocks keep their textual status header.
  defp block_header(%Block{kind: :tool, status: :streaming, title: title}, spinner) do
    spinner_prefix(spinner) <> title
  end

  defp block_header(%Block{} = block, _spinner), do: block_header(block)

  defp spinner_prefix(""), do: ""
  defp spinner_prefix(glyph), do: glyph <> " "

  defp block_header(%Block{kind: :assistant, status: status, title: title}) do
    "assistant#{status_suffix(status, title)}"
  end

  defp block_header(%Block{kind: :tool, status: status, title: title}) do
    "[#{status_label(status)}] #{title}"
  end

  defp block_header(%Block{kind: :permission, status: status, title: title, id: id}) do
    "[#{status_label(status)}] #{title} #{id}"
  end

  defp block_header(%Block{kind: :error, title: title}) do
    "[error] #{title}"
  end

  defp block_header(%Block{kind: :edit, title: title}) do
    "[edit] #{title}"
  end

  defp block_header(%Block{title: title}), do: title

  defp status_suffix(:streaming, "assistant"), do: " streaming"
  defp status_suffix(:streaming, title), do: " #{title} streaming"
  defp status_suffix(_status, "assistant"), do: ""
  defp status_suffix(_status, title), do: " #{title}"

  defp status_label(:streaming), do: "running"
  defp status_label(:done), do: "done"
  defp status_label(:error), do: "error"

  defp body_lines(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line("  " <> &1, width))
  end

  defp wrap_lines(lines, width) do
    Enum.flat_map(lines, &wrap_line(&1, width))
  end

  # Wraps a single line (no embedded newlines) to `width` terminal columns,
  # breaking at whitespace where possible and hard-splitting only words that are
  # themselves wider than `width`. Width is measured in display columns, not
  # graphemes, so wide CJK/emoji do not overflow the viewport.
  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    line
    |> tokenize(width)
    |> pack_tokens(width)
  end

  # Split into alternating word / whitespace tokens, pre-splitting any word that
  # cannot fit on a line so the packer never has to break inside a token.
  defp tokenize(line, width) do
    ~r/\s+|\S+/u
    |> Regex.scan(line)
    |> Enum.flat_map(fn [token] ->
      if whitespace?(token), do: [token], else: hard_wrap(token, width)
    end)
  end

  defp pack_tokens(tokens, width) do
    {lines, current, _current_width} =
      Enum.reduce(tokens, {[], "", 0}, fn token, {lines, current, current_width} ->
        token_width = display_width(token)

        cond do
          current == "" ->
            {lines, token, token_width}

          current_width + token_width <= width ->
            {lines, current <> token, current_width + token_width}

          whitespace?(token) ->
            {[current | lines], "", 0}

          true ->
            {[current | lines], token, token_width}
        end
      end)

    [current | lines]
    |> Enum.reverse()
    |> Enum.map(&String.trim_trailing/1)
  end

  defp hard_wrap(word, width) do
    {pieces, current, _current_width} =
      word
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn grapheme, {pieces, current, current_width} ->
        grapheme_width = grapheme_width(grapheme)

        if current != "" and current_width + grapheme_width > width do
          {[current | pieces], grapheme, grapheme_width}
        else
          {pieces, current <> grapheme, current_width + grapheme_width}
        end
      end)

    Enum.reverse([current | pieces])
  end

  defp whitespace?(token), do: String.trim_leading(token) == ""

  @doc """
  Returns the number of terminal columns a string occupies.

  Width is summed per grapheme using an approximate East-Asian-width table:
  wide CJK and emoji count as 2 columns, combining marks and zero-width
  characters as 0, and everything else as 1. It is an approximation (notably for
  complex emoji ZWJ sequences), good enough to keep wrapping inside the viewport.
  """
  @spec display_width(String.t()) :: non_neg_integer()
  def display_width(string) when is_binary(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn grapheme, acc -> acc + grapheme_width(grapheme) end)
  end

  defp grapheme_width(grapheme) do
    grapheme |> String.to_charlist() |> hd() |> codepoint_width()
  end

  defp codepoint_width(cp) when cp in 0x0300..0x036F, do: 0
  defp codepoint_width(cp) when cp in 0x200B..0x200F, do: 0
  defp codepoint_width(cp) when cp in 0xFE00..0xFE0F, do: 0
  defp codepoint_width(0xFEFF), do: 0
  defp codepoint_width(cp) when cp in 0x1100..0x115F, do: 2
  defp codepoint_width(cp) when cp in 0x2E80..0x303E, do: 2
  defp codepoint_width(cp) when cp in 0x3041..0x33FF, do: 2
  defp codepoint_width(cp) when cp in 0x3400..0x4DBF, do: 2
  defp codepoint_width(cp) when cp in 0x4E00..0x9FFF, do: 2
  defp codepoint_width(cp) when cp in 0xA000..0xA4CF, do: 2
  defp codepoint_width(cp) when cp in 0xAC00..0xD7A3, do: 2
  defp codepoint_width(cp) when cp in 0xF900..0xFAFF, do: 2
  defp codepoint_width(cp) when cp in 0xFE30..0xFE4F, do: 2
  defp codepoint_width(cp) when cp in 0xFF00..0xFF60, do: 2
  defp codepoint_width(cp) when cp in 0xFFE0..0xFFE6, do: 2
  defp codepoint_width(cp) when cp in 0x1F300..0x1FAFF, do: 2
  defp codepoint_width(cp) when cp in 0x20000..0x3FFFD, do: 2
  defp codepoint_width(_cp), do: 1

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp positive_integer_or(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer_or(_value, fallback), do: fallback
end
