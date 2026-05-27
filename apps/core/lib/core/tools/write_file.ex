defmodule Core.Tools.WriteFile do
  @moduledoc """
  Writes a file inside the workspace.
  """

  @behaviour Core.Tool

  alias Core.FileLockManager
  alias Core.Tools.Args
  alias Core.Tools.PathSafety

  @lock_wait_ms 30_000

  @impl true
  def name, do: "write_file"

  @impl true
  def description, do: "Write content to a workspace file."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path", "content"],
      properties: %{
        path: %{type: "string"},
        content: %{type: "string"},
        create_dirs: %{type: "boolean", default: false}
      }
    }
  end

  @impl true
  def safety, do: :write

  @impl true
  def run(args, context) do
    with {:ok, requested_path} <- Args.fetch_string(args, :path),
         {:ok, content} <- Args.string(args, :content),
         {:ok, create_dirs} <- Args.boolean(args, :create_dirs, false),
         {:ok, path} <- PathSafety.resolve(requested_path, context) do
      path.absolute
      |> FileLockManager.with_lock(
        fn -> write(path, content, create_dirs) end,
        manager: lock_manager(context),
        wait_ms: @lock_wait_ms
      )
      |> unwrap_lock()
    end
  end

  defp write(path, content, create_dirs) do
    with :ok <- maybe_create_parent(path.absolute, create_dirs),
         :ok <- File.write(path.absolute, content, [:binary]) do
      bytes = byte_size(content)

      {:ok,
       %{
         path: path.relative,
         bytes_written: bytes,
         summary: "wrote #{path.relative} (#{bytes} bytes)"
       }}
    else
      {:error, reason} -> {:error, {:write_file_failed, path.relative, reason}}
    end
  end

  defp maybe_create_parent(path, true), do: File.mkdir_p(Path.dirname(path))
  defp maybe_create_parent(_path, false), do: :ok

  defp unwrap_lock({:ok, result}), do: result
  defp unwrap_lock({:error, :locked}), do: {:error, :file_locked}

  defp lock_manager(context), do: Map.get(context, :file_lock_manager, FileLockManager)
end
