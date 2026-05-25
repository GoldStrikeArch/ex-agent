defmodule Core.Tools.ListFiles do
  @moduledoc """
  Lists files and directories inside the workspace.
  """

  @behaviour Core.Tool

  alias Core.Tools.Args
  alias Core.Tools.PathSafety

  @default_max_entries 10_000
  @default_max_output_entries 50

  @impl true
  def name, do: "list_files"

  @impl true
  def description, do: "List direct children of a workspace directory."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", default: "."},
        max_entries: %{type: "integer", default: @default_max_entries},
        max_output_entries: %{type: "integer", default: @default_max_output_entries}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, max_entries} <- Args.integer(args, :max_entries, @default_max_entries, 1, 10_000),
         {:ok, max_output_entries} <-
           Args.integer(args, :max_output_entries, @default_max_output_entries, 1, max_entries),
         {:ok, path} <- PathSafety.resolve(Args.get(args, :path, "."), context),
         {:ok, entries, total_count} <- list_entries(path, max_entries) do
      output_entries = Enum.take(entries, max_output_entries)

      {:ok,
       %{
         entries: entries,
         total_entries: total_count,
         shown_entries: length(output_entries),
         entries_truncated: total_count > length(entries),
         output_truncated: length(entries) > length(output_entries),
         output: output_entries |> Enum.map(&format_entry/1) |> Enum.join("\n"),
         summary: summary(total_count, length(entries), length(output_entries))
       }}
    end
  end

  defp list_entries(path, max_entries) do
    with {:ok, stat} <- File.stat(path.absolute),
         :ok <- ensure_directory(stat),
         {:ok, names} <- File.ls(path.absolute) do
      total_count = length(names)

      entries =
        names
        |> Enum.sort()
        |> Enum.take(max_entries)
        |> Enum.map(&entry(path, &1))

      {:ok, entries, total_count}
    else
      {:error, reason} -> {:error, {:list_files_failed, reason}}
      {:not_directory, type} -> {:error, {:not_directory, path.relative, type}}
    end
  end

  defp ensure_directory(%File.Stat{type: :directory}), do: :ok
  defp ensure_directory(%File.Stat{type: type}), do: {:not_directory, type}

  defp entry(path, name) do
    absolute = Path.join(path.absolute, name)
    relative = Path.relative_to(absolute, path.root)

    %{
      path: relative,
      type: file_type(absolute)
    }
  end

  defp file_type(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: type}} -> type
      {:error, _reason} -> :unknown
    end
  end

  defp format_entry(%{type: :directory, path: path}), do: path <> "/"
  defp format_entry(%{path: path}), do: path

  defp summary(total_count, loaded_count, shown_count) do
    total = "#{total_count} #{pluralize(total_count, "entry", "entries")}"

    cond do
      total_count > loaded_count ->
        "#{shown_count} shown, #{loaded_count} loaded of #{total}"

      loaded_count > shown_count ->
        "#{shown_count} shown of #{total}"

      true ->
        total
    end
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
