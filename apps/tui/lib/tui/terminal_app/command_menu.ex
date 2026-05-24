defmodule Tui.TerminalApp.CommandMenu do
  @moduledoc """
  Pure slash-command filtering and selection for the terminal UI.
  """

  @type command :: %{
          id: atom(),
          label: String.t(),
          description: String.t()
        }

  @commands [
    %{id: :help, label: "/help", description: "show command help"},
    %{id: :status, label: "/status", description: "show session and tool state"},
    %{id: :clear, label: "/clear", description: "clear the transcript viewport"},
    %{id: :quit, label: "/quit", description: "exit the UI"}
  ]

  @doc """
  Returns the supported commands.
  """
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc """
  Returns true while the prompt should show slash-command suggestions.
  """
  @spec visible?(String.t()) :: boolean()
  def visible?(prompt), do: String.starts_with?(prompt, "/")

  @doc """
  Filters commands by prompt prefix.
  """
  @spec filtered(String.t()) :: [command()]
  def filtered(prompt) when is_binary(prompt) do
    query = query(prompt)

    Enum.filter(@commands, fn command ->
      command.label
      |> String.trim_leading("/")
      |> String.starts_with?(query)
    end)
  end

  @doc """
  Clamps a selected index to the current filtered command list.
  """
  @spec clamp_index(integer(), String.t()) :: non_neg_integer()
  def clamp_index(index, prompt) when is_integer(index) and is_binary(prompt) do
    max_index = max(0, length(filtered(prompt)) - 1)
    index |> max(0) |> min(max_index)
  end

  @doc """
  Moves the selected command by `delta`.
  """
  @spec move(integer(), integer(), String.t()) :: non_neg_integer()
  def move(index, delta, prompt) do
    commands = filtered(prompt)
    count = length(commands)

    if count == 0 do
      0
    else
      rem(index + delta + count, count)
    end
  end

  @doc """
  Picks a command to execute from the prompt and selected index.
  """
  @spec selected(String.t(), integer()) :: {:ok, command()} | {:error, term()}
  def selected(prompt, index) when is_binary(prompt) and is_integer(index) do
    prompt
    |> filtered()
    |> Enum.at(clamp_index(index, prompt))
    |> case do
      nil -> {:error, {:unknown_command, prompt}}
      command -> {:ok, command}
    end
  end

  @doc """
  Renders compact menu lines.
  """
  @spec lines(String.t(), integer(), pos_integer()) :: [String.t()]
  def lines(<<"/", _rest::binary>> = prompt, selected_index, width)
      when is_integer(selected_index) and is_integer(width) do
    prompt
    |> filtered()
    |> render_lines(prompt, selected_index, width)
  end

  def lines(prompt, _selected_index, _width) when is_binary(prompt), do: []

  @doc """
  Returns help text for the full command panel.
  """
  @spec help_lines() :: [String.t()]
  def help_lines do
    Enum.map(@commands, &row/1)
  end

  defp query("/"), do: ""

  defp query("/" <> rest) do
    rest
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.downcase()
  end

  defp query(_prompt), do: ""

  defp render_lines([], prompt, _selected_index, width) do
    [fit_line("  no command matches #{inspect(prompt)}", width)]
  end

  defp render_lines(commands, _prompt, selected_index, width) do
    selected_index = clamp_index_for_commands(selected_index, commands)

    commands
    |> Enum.with_index()
    |> Enum.map(&command_line(&1, selected_index, width))
  end

  defp command_line({command, index}, selected_index, width) do
    prefix = if index == selected_index, do: "> ", else: "  "
    fit_line(prefix <> row(command), width)
  end

  defp clamp_index_for_commands(index, commands) do
    index
    |> max(0)
    |> min(length(commands) - 1)
  end

  defp row(%{label: label, description: description}) do
    String.pad_trailing(label, 10) <> description
  end

  defp fit_line(line, width) when width > 0 do
    line
    |> String.graphemes()
    |> Enum.take(width)
    |> Enum.join()
  end
end
