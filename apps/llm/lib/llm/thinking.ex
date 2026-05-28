defmodule LLM.Thinking do
  @moduledoc """
  Normalizes user-facing model thinking levels for Responses-compatible clients.

  The UI calls these values "thinking levels" while OpenAI-compatible request
  bodies encode the same setting as `reasoning.effort`.
  """

  @levels ~w(minimal low medium high)

  @type level :: String.t()

  @doc """
  Returns the supported thinking levels in increasing effort order.
  """
  @spec levels() :: [level()]
  def levels, do: @levels

  @doc """
  Normalizes a thinking level value.

  Empty, nil, or `"default"` values return `{:ok, nil}` so callers can omit the
  `reasoning` request field and let the provider choose its default.
  """
  @spec normalize(term()) :: {:ok, level() | nil} | {:error, term()}
  def normalize(nil), do: {:ok, nil}
  def normalize(""), do: {:ok, nil}
  def normalize(:default), do: {:ok, nil}

  def normalize(level) when is_atom(level) do
    level
    |> Atom.to_string()
    |> normalize()
  end

  def normalize(level) when is_binary(level) do
    level
    |> String.trim()
    |> String.downcase()
    |> normalize_binary()
  end

  def normalize(level), do: {:error, {:invalid_thinking_level, level, @levels}}

  @doc """
  Converts request options into a Responses `reasoning` payload.

  Reads `:reasoning_effort` first and falls back to `:thinking_level` so callers
  can use either the provider-facing or UI-facing name.
  """
  @spec reasoning(keyword()) :: {:ok, %{effort: level()} | nil} | {:error, term()}
  def reasoning(opts) when is_list(opts) do
    opts
    |> Keyword.get(:reasoning_effort, Keyword.get(opts, :thinking_level))
    |> normalize()
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, level} -> {:ok, %{effort: level}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Formats a thinking level for status text.
  """
  @spec label(level() | nil) :: String.t()
  def label(nil), do: "default"
  def label(level) when is_binary(level), do: level

  defp normalize_binary(""), do: {:ok, nil}
  defp normalize_binary("default"), do: {:ok, nil}
  defp normalize_binary("none"), do: {:ok, nil}
  defp normalize_binary("min"), do: {:ok, "minimal"}
  defp normalize_binary("max"), do: {:ok, "high"}

  defp normalize_binary(level) do
    if level in @levels do
      {:ok, level}
    else
      {:error, {:invalid_thinking_level, level, @levels}}
    end
  end
end
