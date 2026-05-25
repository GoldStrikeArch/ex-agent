defmodule Core.Tools.EditFile do
  @moduledoc """
  Replaces text in a workspace file.
  """

  @behaviour Core.Tool

  alias Core.FileLockManager
  alias Core.Tools.Args
  alias Core.Tools.PathSafety

  @impl true
  def name, do: "edit_file"

  @impl true
  def description, do: "Replace text in a workspace file."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path", "search", "replace"],
      properties: %{
        path: %{type: "string"},
        search: %{type: "string"},
        replace: %{type: "string"},
        occurrence: %{type: "string", enum: ["first", "all"], default: "first"},
        expected_replacements: %{type: "integer"}
      }
    }
  end

  @impl true
  def safety, do: :write

  @impl true
  def run(args, context) do
    with {:ok, requested_path} <- Args.fetch_string(args, :path),
         {:ok, search} <- Args.fetch_string(args, :search),
         {:ok, replace} <- Args.string(args, :replace),
         {:ok, occurrence} <- occurrence(args),
         {:ok, expected} <- Args.optional_integer(args, :expected_replacements, 0, 1_000_000),
         {:ok, path} <- PathSafety.resolve(requested_path, context) do
      path.absolute
      |> FileLockManager.with_lock(
        fn -> edit(path, search, replace, occurrence, expected) end,
        lock_manager(context)
      )
      |> unwrap_lock()
    end
  end

  defp occurrence(args) do
    case Args.get(args, :occurrence, "first") do
      value when value in ["first", "all"] -> {:ok, value}
      value -> {:error, {:invalid_argument, :occurrence, value}}
    end
  end

  defp edit(path, search, replace, occurrence, expected) do
    with {:ok, content} <- read(path),
         {:ok, edited, replacements} <- replace_content(content, search, replace, occurrence),
         :ok <- verify_expected(expected, replacements),
         :ok <- File.write(path.absolute, edited, [:binary]) do
      {:ok, result(path.relative, edited, replacements)}
    else
      {:error, reason} -> {:error, normalize_error(path.relative, reason)}
    end
  end

  defp read(path) do
    case File.read(path.absolute) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_file_failed, reason}}
    end
  end

  defp replace_content(content, search, replace, "first") do
    case String.split(content, search, parts: 2) do
      [_content] -> {:error, :search_not_found}
      [prefix, suffix] -> {:ok, prefix <> replace <> suffix, 1}
    end
  end

  defp replace_content(content, search, replace, "all") do
    content
    |> String.split(search)
    |> replace_all_parts(replace)
  end

  defp replace_all_parts([_content], _replace), do: {:error, :search_not_found}

  defp replace_all_parts(parts, replace) do
    replacements = length(parts) - 1

    edited =
      parts
      |> Enum.intersperse(replace)
      |> IO.iodata_to_binary()

    {:ok, edited, replacements}
  end

  defp verify_expected(nil, _replacements), do: :ok
  defp verify_expected(count, count), do: :ok

  defp verify_expected(expected, actual),
    do: {:error, {:replacement_count_mismatch, expected, actual}}

  defp result(relative_path, edited, replacements) do
    %{
      path: relative_path,
      replacements: replacements,
      bytes_written: byte_size(edited),
      summary: "edited #{relative_path} (#{replacements} #{pluralize(replacements)})"
    }
  end

  defp normalize_error(path, :search_not_found), do: {:search_not_found, path}
  defp normalize_error(path, reason), do: {:edit_file_failed, path, reason}

  defp unwrap_lock({:ok, result}), do: result
  defp unwrap_lock({:error, :locked}), do: {:error, :file_locked}

  defp lock_manager(context), do: Map.get(context, :file_lock_manager, FileLockManager)

  defp pluralize(1), do: "replacement"
  defp pluralize(_count), do: "replacements"
end
