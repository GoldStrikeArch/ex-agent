defmodule Core.Tools.Structural.AstQuery do
  @moduledoc """
  Runs a compact structural query against the parsed index.
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
        path: %{type: "string"},
        limit: %{type: "integer", default: 100}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, query} <- Args.fetch_string(args, :query),
         {:ok, limit} <- Args.optional_integer(args, :limit, 1, 1000) do
      params = %{query: query, path: Args.get(args, :path), limit: limit}
      Structural.dispatch(:ast_query, params, context, Map.take(params, [:query, :path, :limit]))
    end
  end
end
