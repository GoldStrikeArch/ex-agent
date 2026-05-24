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
          required(:args) => map(),
          optional(:provider_id) => String.t()
        }

  @doc """
  Normalizes a single model tool-call payload.

  Accepts atom-keyed or string-keyed maps. Expected failures return tagged
  tuples so provider adapters can pass raw decoded JSON without raising.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(%{id: id, name: name, args: args} = call),
    do: normalize_values(id, name, args, call)

  def normalize(%{"id" => id, "name" => name, "args" => args} = call),
    do: normalize_values(id, name, args, call)

  def normalize(%{id: id, name: name, arguments: args} = call),
    do: normalize_values(id, name, args, call)

  def normalize(%{"id" => id, "name" => name, "arguments" => args} = call) do
    normalize_values(id, name, args, call)
  end

  def normalize(%{name: name, args: args} = call),
    do: normalize_values(new_tool_call_id(), name, args, call)

  def normalize(%{"name" => name, "args" => args} = call) do
    normalize_values(new_tool_call_id(), name, args, call)
  end

  def normalize(%{name: name, arguments: args} = call),
    do: normalize_values(new_tool_call_id(), name, args, call)

  def normalize(%{"name" => name, "arguments" => args} = call) do
    normalize_values(new_tool_call_id(), name, args, call)
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

  defp normalize_values(id, name, args, call)
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(args) do
    base = %{id: id, name: name, args: args}

    {:ok, maybe_put_provider_id(base, provider_id(call))}
  end

  defp normalize_values(id, name, args, _call) do
    {:error, {:invalid_tool_call, %{id: id, name: name, args: args}}}
  end

  defp provider_id(call), do: Map.get(call, :provider_id, Map.get(call, "provider_id"))

  defp maybe_put_provider_id(call, provider_id)
       when is_binary(provider_id) and provider_id != "" do
    Map.put(call, :provider_id, provider_id)
  end

  defp maybe_put_provider_id(call, _provider_id), do: call

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
