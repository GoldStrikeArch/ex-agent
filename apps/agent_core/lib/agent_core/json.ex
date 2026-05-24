defmodule AgentCore.Json do
  @moduledoc false

  @spec encode!(term()) :: String.t()
  def encode!(term) do
    term
    |> encode()
    |> IO.iodata_to_binary()
  end

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(value) when is_binary(value), do: [?\", escape(value), ?\"]
  defp encode(value) when is_atom(value), do: value |> Atom.to_string() |> encode()
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_float(value), do: Float.to_string(value)

  defp encode(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> encode()
  end

  defp encode(value) when is_list(value) do
    ["[", value |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]
  end

  defp encode(%{} = value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {key_to_string(key), item} end)
      |> Enum.sort_by(fn {key, _item} -> key end)
      |> Enum.map(fn {key, item} -> [encode(key), ":", encode(item)] end)
      |> Enum.intersperse(",")

    ["{", entries, "}"]
  end

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

  defp escape(value) do
    value
    |> String.to_charlist()
    |> Enum.map(&escape_char/1)
  end

  defp escape_char(?"), do: ~S(\")
  defp escape_char(?\\), do: ~S(\\)
  defp escape_char(?\n), do: ~S(\n)
  defp escape_char(?\r), do: ~S(\r)
  defp escape_char(?\t), do: ~S(\t)

  defp escape_char(char) when char < 32,
    do: "\\u" <> String.pad_leading(Integer.to_string(char, 16), 4, "0")

  defp escape_char(char), do: char
end
