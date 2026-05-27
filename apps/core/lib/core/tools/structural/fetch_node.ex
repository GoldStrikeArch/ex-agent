defmodule Core.Tools.Structural.FetchNode do
  @moduledoc """
  Fetches the exact source slice for a structural node.

  Stub tool: returns a `:backend_unavailable` result until a real structural
  backend is wired up.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "fetch_node"

  @impl true
  def description, do: "Fetch the exact source for a symbol node by id, with hash-checked ranges."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["symbol_id"],
      properties: %{
        symbol_id: %{type: "string"},
        include_comments: %{type: "boolean", default: true}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, symbol_id} <- Args.fetch_string(args, :symbol_id),
         {:ok, include_comments} <- Args.boolean(args, :include_comments, true) do
      params = %{symbol_id: symbol_id, include_comments: include_comments}
      Structural.dispatch(:fetch_node, params, context, %{symbol_id: symbol_id})
    end
  end
end
