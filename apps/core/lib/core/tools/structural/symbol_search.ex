defmodule Core.Tools.Structural.SymbolSearch do
  @moduledoc """
  Finds symbol definitions by name across the workspace.

  Stub tool: returns a `:backend_unavailable` result until a real structural
  backend is wired up.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "symbol_search"

  @impl true
  def description,
    do: "Locate module, function, or class definitions by name, optionally scoped to a path."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["query"],
      properties: %{
        query: %{type: "string"},
        kind: %{type: "string"},
        path: %{type: "string"},
        limit: %{type: "integer", default: 50}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, query} <- Args.fetch_string(args, :query),
         {:ok, limit} <- Args.optional_integer(args, :limit, 1, 1000) do
      params = %{
        query: query,
        kind: Args.get(args, :kind),
        path: Args.get(args, :path),
        limit: limit
      }

      Structural.dispatch(
        :symbol_search,
        params,
        context,
        Map.take(params, [:query, :path, :limit])
      )
    end
  end
end
