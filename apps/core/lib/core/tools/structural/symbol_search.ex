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
    do: "Locate module, function, or class definitions by name across the workspace."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["query"],
      properties: %{
        query: %{type: "string"},
        kind: %{type: "string"}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, query} <- Args.fetch_string(args, :query) do
      params = %{query: query, kind: Args.get(args, :kind)}
      Structural.dispatch(:symbol_search, params, context, %{query: query})
    end
  end
end
