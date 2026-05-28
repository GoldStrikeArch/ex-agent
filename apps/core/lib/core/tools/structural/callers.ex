defmodule Core.Tools.Structural.Callers do
  @moduledoc """
  Finds call sites for a symbol.

  Stub tool: returns a `:backend_unavailable` result until a real structural
  backend is wired up.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "callers"

  @impl true
  def description, do: "Find call sites that reference a symbol, optionally scoped to a path."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["symbol"],
      properties: %{
        symbol: %{type: "string"},
        path: %{type: "string"},
        limit: %{type: "integer", default: 50}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, symbol} <- Args.fetch_string(args, :symbol),
         {:ok, limit} <- Args.optional_integer(args, :limit, 1, 1000) do
      params = %{symbol: symbol, path: Args.get(args, :path), limit: limit}
      Structural.dispatch(:callers, params, context, Map.take(params, [:symbol, :path, :limit]))
    end
  end
end
