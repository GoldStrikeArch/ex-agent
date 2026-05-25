defmodule Tui.TerminalApp.Transcript do
  @moduledoc """
  Maintains structured transcript blocks for the interactive terminal UI.

  `Tui.TextRenderer` remains the canonical append-only text renderer for
  replay and logs. This module keeps live UI state rich enough to update active
  assistant messages, tools, permissions, and edit previews in place.
  """

  alias Tui.Transcript.Block

  defstruct active_messages: %{},
            active_permissions: MapSet.new(),
            active_tools: %{},
            blocks: [],
            follow?: true,
            max_blocks: 250,
            top: 0

  @type tool_state :: %{
          name: String.t(),
          args: map(),
          output_bytes: non_neg_integer()
        }

  @type t :: %__MODULE__{
          active_messages: %{String.t() => atom()},
          active_permissions: term(),
          active_tools: %{String.t() => tool_state()},
          blocks: [Block.t()],
          follow?: boolean(),
          max_blocks: pos_integer(),
          top: non_neg_integer()
        }

  @type scroll_direction :: :page_up | :page_down | :top | :bottom

  @doc """
  Builds an empty transcript.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_blocks = opts |> Keyword.get(:max_blocks, 250) |> positive_integer_or(250)
    %__MODULE__{max_blocks: max_blocks}
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
    call_id = to_string(call_id)
    tool = %{name: name, args: args, output_bytes: 0}

    transcript
    |> Map.update!(:active_tools, &Map.put(&1, call_id, tool))
    |> append_block(tool_block(call_id, tool, :streaming, "running"))
  end

  def append_event(%__MODULE__{} = transcript, {:tool_output, call_id, chunk})
      when is_binary(chunk) do
    call_id = to_string(call_id)
    tool = Map.get(transcript.active_tools, call_id, %{name: call_id, args: %{}, output_bytes: 0})
    tool = Map.update!(tool, :output_bytes, &(&1 + byte_size(chunk)))

    transcript
    |> Map.update!(:active_tools, &Map.put(&1, call_id, tool))
    |> replace_block(call_id, tool_block(call_id, tool, :streaming, "running"))
  end

  def append_event(%__MODULE__{} = transcript, {:tool_finished, call_id, status, summary}) do
    call_id = to_string(call_id)
    {tool, active_tools} = Map.pop(transcript.active_tools, call_id)
    tool = tool || %{name: call_id, args: %{}, output_bytes: 0}
    block_status = block_status(status)

    transcript
    |> Map.put(:active_tools, active_tools)
    |> replace_or_append_block(
      call_id,
      tool_block(call_id, tool, block_status, format_summary(summary))
    )
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
  def visible_lines(%__MODULE__{} = transcript, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    lines = all_lines(transcript, width)
    total = length(lines)

    if transcript.follow? or total <= height do
      Enum.take(lines, -height)
    else
      top = clamp_top(transcript.top, total, height)

      lines
      |> Enum.drop(top)
      |> Enum.take(height)
    end
  end

  def visible_lines(%__MODULE__{}, _width, _height), do: []

  @doc """
  Scrolls the viewport. Reaching the bottom re-enables auto-follow.
  """
  @spec scroll(t(), scroll_direction(), pos_integer(), pos_integer()) :: t()
  def scroll(%__MODULE__{} = transcript, direction, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    total = transcript |> all_lines(width) |> length()
    max_top = max(0, total - height)
    current = if transcript.follow?, do: max_top, else: clamp_top(transcript.top, total, height)

    top =
      direction
      |> next_top(current, max_top, height)
      |> max(0)
      |> min(max_top)

    %{transcript | top: top, follow?: top >= max_top}
  end

  def scroll(%__MODULE__{} = transcript, _direction, _width, _height), do: transcript

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
        blocks: [],
        follow?: true,
        top: 0
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
    title = "tool #{tool.name}"
    body = ["output #{tool.output_bytes} B", summary_line(summary), args_line(tool.args)]
    block(call_id, :tool, status, title, Enum.reject(body, &(&1 == "")))
  end

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
  defp summary_line(summary), do: "summary #{summary}"

  defp args_line(args) when args == %{}, do: ""
  defp args_line(args), do: "args #{inspect(args)}"

  defp all_lines(transcript, width) do
    transcript.blocks
    |> Enum.reverse()
    |> Enum.flat_map(&block_lines(&1, width))
  end

  defp clamp_top(top, total, height) do
    top
    |> max(0)
    |> min(max(0, total - height))
  end

  defp next_top(:page_up, current, _max_top, height), do: current - height
  defp next_top(:page_down, current, _max_top, height), do: current + height
  defp next_top(:top, _current, _max_top, _height), do: 0
  defp next_top(:bottom, _current, max_top, _height), do: max_top

  defp block_lines(%Block{kind: :system, body: []} = block, width) do
    wrap_line(block.title, width)
  end

  defp block_lines(%Block{kind: :user} = block, width) do
    block
    |> body_text()
    |> then(&["user> " <> &1])
    |> wrap_lines(width)
  end

  defp block_lines(%Block{} = block, width) do
    header = block_header(block)
    body = Enum.flat_map(block.body, &body_lines(&1, width))
    wrap_line(header, width) ++ body
  end

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

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp positive_integer_or(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer_or(_value, fallback), do: fallback
end
