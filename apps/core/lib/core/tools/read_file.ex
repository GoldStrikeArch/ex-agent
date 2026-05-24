defmodule Core.Tools.ReadFile do
  @moduledoc """
  Reads a UTF-8 file from the workspace.
  """

  @behaviour Core.Tool

  alias Core.Tools.Args
  alias Core.Tools.PathSafety

  @default_max_bytes 128 * 1_024

  @impl true
  def name, do: "read_file"

  @impl true
  def description, do: "Read a file from the workspace."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path"],
      properties: %{
        path: %{type: "string"},
        max_bytes: %{type: "integer", default: @default_max_bytes}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, max_bytes} <- Args.integer(args, :max_bytes, @default_max_bytes, 1, 1_000_000),
         {:ok, requested_path} <- Args.fetch_string(args, :path),
         {:ok, path} <- PathSafety.resolve(requested_path, context),
         {:ok, content, truncated} <- read_limited(path.absolute, max_bytes) do
      bytes = byte_size(content)

      {:ok,
       %{
         path: path.relative,
         content: content,
         bytes: bytes,
         truncated: truncated,
         output: content,
         summary: "read #{path.relative} (#{bytes} bytes#{truncated_label(truncated)})"
       }}
    end
  end

  defp read_limited(path, max_bytes) do
    with {:ok, stat} <- File.stat(path),
         :ok <- ensure_regular_file(stat),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      read_result = IO.binread(io, max_bytes + 1)
      File.close(io)
      normalize_read(read_result, max_bytes)
    else
      {:error, reason} -> {:error, {:read_file_failed, reason}}
      {:not_file, type} -> {:error, {:not_file, path, type}}
    end
  end

  defp ensure_regular_file(%File.Stat{type: :regular}), do: :ok
  defp ensure_regular_file(%File.Stat{type: type}), do: {:not_file, type}

  defp normalize_read(:eof, _max_bytes), do: {:ok, "", false}
  defp normalize_read({:error, reason}, _max_bytes), do: {:error, {:read_file_failed, reason}}

  defp normalize_read(content, max_bytes) when byte_size(content) > max_bytes do
    {:ok, binary_part(content, 0, max_bytes), true}
  end

  defp normalize_read(content, _max_bytes) when is_binary(content), do: {:ok, content, false}

  defp truncated_label(true), do: ", truncated"
  defp truncated_label(false), do: ""
end
