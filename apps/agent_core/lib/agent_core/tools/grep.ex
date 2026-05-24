defmodule AgentCore.Tools.Grep do
  @moduledoc """
  Searches workspace files with ripgrep.
  """

  @behaviour AgentCore.Tool

  alias AgentCore.Tools.Args
  alias AgentCore.Tools.PathSafety

  @impl true
  def name, do: "grep"

  @impl true
  def description, do: "Search workspace files for a text or regex pattern."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["pattern"],
      properties: %{
        pattern: %{type: "string"},
        path: %{type: "string", default: "."},
        max_matches: %{type: "integer", default: 100}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, pattern} <- Args.fetch_string(args, :pattern),
         {:ok, max_matches} <- Args.integer(args, :max_matches, 100, 1, 1_000),
         {:ok, path} <- PathSafety.resolve(Args.get(args, :path, "."), context),
         {:ok, rg} <- find_ripgrep() do
      run_ripgrep(rg, pattern, path, max_matches)
    end
  end

  defp find_ripgrep do
    case System.find_executable("rg") do
      nil -> {:error, :ripgrep_not_found}
      path -> {:ok, path}
    end
  end

  defp run_ripgrep(rg, pattern, path, max_matches) do
    args = [
      "--line-number",
      "--column",
      "--color",
      "never",
      "--no-heading",
      "--",
      pattern,
      path.relative
    ]

    case System.cmd(rg, args, cd: path.root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, result(output, max_matches)}
      {_output, 1} -> {:ok, result("", max_matches)}
      {output, exit_status} -> {:error, {:ripgrep_failed, exit_status, output}}
    end
  end

  defp result(output, max_matches) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.take(max_matches)

    matches = Enum.map(lines, &parse_match/1)
    count = length(matches)

    %{
      matches: matches,
      output: Enum.join(lines, "\n"),
      summary: "#{count} #{pluralize(count, "match", "matches")}"
    }
  end

  defp parse_match(line) do
    case String.split(line, ":", parts: 4) do
      [path, line_number, column, text] ->
        %{
          path: path,
          line: parse_number(line_number),
          column: parse_number(column),
          text: text
        }

      _other ->
        %{text: line}
    end
  end

  defp parse_number(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
