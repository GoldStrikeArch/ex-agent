defmodule AgentCore.Tools.PathSafety do
  @moduledoc false

  @type resolved_path :: %{
          root: Path.t(),
          absolute: Path.t(),
          relative: Path.t()
        }

  @spec resolve(term(), AgentCore.Tool.context()) :: {:ok, resolved_path()} | {:error, term()}
  def resolve(path, context) when is_binary(path) and path != "" do
    root = context.workspace_root |> Path.expand() |> Path.absname()
    absolute = Path.expand(path, root)

    if inside_workspace?(absolute, root) do
      {:ok, %{root: root, absolute: absolute, relative: relative_path(absolute, root)}}
    else
      {:error, {:path_outside_workspace, path}}
    end
  end

  def resolve(path, _context), do: {:error, {:invalid_argument, :path, path}}

  defp inside_workspace?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp relative_path(path, root) do
    case Path.relative_to(path, root) do
      "" -> "."
      relative -> relative
    end
  end
end
