defmodule Core.Tools.ListFiles do
  @moduledoc """
  Lists files and directories inside the workspace.
  """

  @behaviour Core.Tool

  alias Core.Tools.Args
  alias Core.Tools.PathSafety

  @impl true
  def name, do: "list_files"

  @impl true
  def description, do: "List direct children of a workspace directory."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", default: "."}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, path} <- PathSafety.resolve(Args.get(args, :path, "."), context),
         {:ok, entries} <- list_entries(path) do
      count = length(entries)

      {:ok,
       %{
         entries: entries,
         output: entries |> Enum.map(&format_entry/1) |> Enum.join("\n"),
         summary: "#{count} #{pluralize(count, "entry", "entries")}"
       }}
    end
  end

  defp list_entries(path) do
    with {:ok, stat} <- File.stat(path.absolute),
         :ok <- ensure_directory(stat),
         {:ok, names} <- File.ls(path.absolute) do
      entries =
        names
        |> Enum.sort()
        |> Enum.map(&entry(path, &1))

      {:ok, entries}
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

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
