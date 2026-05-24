defmodule AgentTui.InputLoop do
  @moduledoc """
  Simple line-oriented input loop for interactive terminal sessions.

  This deliberately avoids raw terminal mode. Multiline prompts are collected
  through `$EDITOR` so the TUI can stay scrollback-friendly until richer input
  pressure is real.
  """

  @type parsed_line ::
          :ignore
          | {:command, :editor | :help | :quit}
          | {:error, {:unknown_command, String.t()}}
          | {:prompt, String.t()}

  @help """
  Commands:
    /help    Show this help
    /editor  Compose a multiline prompt in $EDITOR
    /quit    Exit the session
  """

  @doc """
  Runs the input loop until EOF, `/quit`, or an input error.
  """
  @spec run(pid(), keyword()) :: :ok | {:error, term()}
  def run(session, opts \\ []) when is_pid(session) do
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stdio)

    loop(session, input, output, opts)
  end

  @doc """
  Parses one line of user input.
  """
  @spec parse_line(String.t()) :: parsed_line()
  def parse_line(line) when is_binary(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
    |> do_parse_line()
  end

  @doc """
  Handles one input line for a session.
  """
  @spec handle_line(String.t(), pid(), keyword()) :: :continue | :quit | {:error, term()}
  def handle_line(line, session, opts \\ []) when is_pid(session) and is_binary(line) do
    output = Keyword.get(opts, :output, :stdio)

    case parse_line(line) do
      :ignore ->
        :continue

      {:prompt, prompt} ->
        submit_prompt(session, prompt, output)

      {:command, :help} ->
        IO.write(output, @help)
        :continue

      {:command, :quit} ->
        :quit

      {:command, :editor} ->
        handle_editor_command(session, output, opts)

      {:error, {:unknown_command, command}} ->
        IO.write(output, ["unknown command: ", command, "\nType /help for commands.\n"])
        :continue
    end
  end

  @doc """
  Sends a prompt to an agent session.
  """
  @spec submit_prompt(pid(), String.t(), IO.device()) :: :continue | {:error, term()}
  def submit_prompt(session, prompt, output \\ :stdio)
      when is_pid(session) and is_binary(prompt) do
    case AgentCore.send_message(session, prompt) do
      {:ok, _reply} ->
        :continue

      {:error, reason} ->
        IO.write(output, ["error: ", inspect(reason), "\n"])
        {:error, reason}
    end
  end

  defp loop(session, input, output, opts) do
    case IO.gets(input, "agent> ") do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}

      line ->
        case handle_line(line, session, Keyword.put(opts, :output, output)) do
          :continue -> loop(session, input, output, opts)
          :quit -> :ok
          {:error, _reason} = error -> error
        end
    end
  end

  defp do_parse_line(""), do: :ignore
  defp do_parse_line("/help"), do: {:command, :help}
  defp do_parse_line("/quit"), do: {:command, :quit}
  defp do_parse_line("/editor"), do: {:command, :editor}

  defp do_parse_line(<<"/", rest::binary>> = command) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [name | _rest] -> {:error, {:unknown_command, "/" <> name}}
      [] -> {:error, {:unknown_command, command}}
    end
  end

  defp do_parse_line(prompt), do: {:prompt, String.trim(prompt)}

  defp handle_editor_command(session, output, opts) do
    case read_editor_prompt(opts) do
      {:ok, prompt} ->
        prompt
        |> String.trim()
        |> maybe_submit_editor_prompt(session, output)

      {:error, :editor_not_configured} ->
        IO.write(output, "Set EDITOR to use /editor.\n")
        :continue

      {:error, reason} ->
        IO.write(output, ["editor error: ", inspect(reason), "\n"])
        :continue
    end
  end

  defp maybe_submit_editor_prompt("", _session, _output), do: :continue

  defp maybe_submit_editor_prompt(prompt, session, output) do
    submit_prompt(session, prompt, output)
  end

  defp read_editor_prompt(opts) do
    with {:ok, editor} <- fetch_editor(opts),
         {:ok, path} <- write_editor_seed(opts),
         :ok <- run_editor(editor, path),
         {:ok, contents} <- File.read(path) do
      File.rm(path)
      {:ok, contents}
    end
  end

  defp fetch_editor(opts) do
    case Keyword.get(opts, :editor) || System.get_env("EDITOR") do
      editor when is_binary(editor) and editor != "" -> {:ok, editor}
      _other -> {:error, :editor_not_configured}
    end
  end

  defp write_editor_seed(opts) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-tui-prompt-#{System.unique_integer([:positive])}.md"
      )

    seed = Keyword.get(opts, :editor_seed, "")

    case File.write(path, seed) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_editor(editor, path) do
    command = [editor, " ", shell_escape(path)]

    case System.shell(IO.iodata_to_binary(command)) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:editor_failed, status, output}}
    end
  end

  defp shell_escape(path) do
    ["'", String.replace(path, "'", "'\"'\"'"), "'"]
  end
end
