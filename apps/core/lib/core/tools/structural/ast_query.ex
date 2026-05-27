defmodule Core.Tools.Structural.AstQuery do
  @moduledoc """
  Runs a structural query against parsed syntax trees.

  Stub tool: returns a `:backend_unavailable` result until a real structural
  backend is wired up.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "ast_query"

  @impl true
  def description, do: "Run a structural pattern query against parsed syntax trees."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["query"],
      properties: %{
        query: %{type: "string"},
        path: %{type: "string"}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, query} <- Args.fetch_string(args, :query) do
      params = %{query: query, path: Args.get(args, :path)}
      Structural.dispatch(:ast_query, params, context, %{query: query})
    end
  end
end
