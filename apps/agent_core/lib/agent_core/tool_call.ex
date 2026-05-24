defmodule AgentCore.ToolCall do
  @moduledoc """
  Normalizes model-requested tool calls into the internal session shape.

  Tool calls use atom keys inside the core:

      %{
        id: "tool-1",
        name: "read_file",
        args: %{"path" => "mix.exs"}
      }

  Missing IDs are filled in at the boundary so downstream tool events and tool
  result messages can share one stable call ID.
  """

  @typedoc """
  Internal model tool-call request.
  """
  @type t :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:args) => map()
        }

  @doc """
  Normalizes a single model tool-call payload.

  Accepts atom-keyed or string-keyed maps. Expected failures return tagged
  tuples so provider adapters can pass raw decoded JSON without raising.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(%{id: id, name: name, args: args}), do: normalize_values(id, name, args)

  def normalize(%{"id" => id, "name" => name, "args" => args}),
    do: normalize_values(id, name, args)

  def normalize(%{id: id, name: name, arguments: args}), do: normalize_values(id, name, args)

  def normalize(%{"id" => id, "name" => name, "arguments" => args}) do
    normalize_values(id, name, args)
  end

  def normalize(%{name: name, args: args}), do: normalize_values(new_tool_call_id(), name, args)

  def normalize(%{"name" => name, "args" => args}) do
    normalize_values(new_tool_call_id(), name, args)
  end

  def normalize(%{name: name, arguments: args}),
    do: normalize_values(new_tool_call_id(), name, args)

  def normalize(%{"name" => name, "arguments" => args}) do
    normalize_values(new_tool_call_id(), name, args)
  end

  def normalize(call), do: {:error, {:invalid_tool_call, call}}

  @doc """
  Normalizes a list of model tool-call payloads in order.
  """
  @spec normalize_all(term()) :: {:ok, [t()]} | {:error, term()}
  def normalize_all(calls) when is_list(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, &normalize_next/2)
    |> reverse_calls()
  end

  def normalize_all(calls), do: {:error, {:invalid_tool_calls, calls}}

  defp normalize_values(id, name, args)
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(args) do
    {:ok, %{id: id, name: name, args: args}}
  end

  defp normalize_values(id, name, args) do
    {:error, {:invalid_tool_call, %{id: id, name: name, args: args}}}
  end

  defp normalize_next(call, {:ok, calls}) do
    case normalize(call) do
      {:ok, normalized} -> {:cont, {:ok, [normalized | calls]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reverse_calls({:ok, calls}), do: {:ok, Enum.reverse(calls)}
  defp reverse_calls(error), do: error

  defp new_tool_call_id do
    "tool-" <>
      (System.unique_integer([:positive, :monotonic])
       |> Integer.to_string(36))
  end
end
