defmodule Core.Tools.Args do
  @moduledoc false

  def get(args, key, default \\ nil) when is_map(args) and is_atom(key) do
    Map.get(args, key, Map.get(args, Atom.to_string(key), default))
  end

  def fetch_string(args, key) do
    case get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_argument, key, value}}
    end
  end

  def integer(args, key, default, min, max) do
    value = get(args, key, default)

    case parse_integer(value) do
      {:ok, integer} -> {:ok, integer |> Kernel.max(min) |> Kernel.min(max)}
      :error -> {:error, {:invalid_argument, key, value}}
    end
  end

  def boolean(args, key, default) do
    case get(args, key, default) do
      value when is_boolean(value) -> {:ok, value}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      value -> {:error, {:invalid_argument, key, value}}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :error
    end
  end

  defp parse_integer(_value), do: :error
end
