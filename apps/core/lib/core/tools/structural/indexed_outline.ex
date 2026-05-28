defmodule Core.Tools.Structural.IndexedOutline do
  @moduledoc """
  Returns compact outlines for indexed files under an optional path.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "indexed_outline"

  @impl true
  def description,
    do: "List indexed files and their symbols recursively under an optional workspace path."

  @impl true
  def schema do
    %{
      type: "object",
      required: [],
      properties: %{
        path: %{type: "string"},
        limit: %{type: "integer", default: 200},
        symbol_limit_per_file: %{type: "integer", default: 200}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, limit} <- Args.optional_integer(args, :limit, 1, 1000),
         {:ok, symbol_limit} <- Args.optional_integer(args, :symbol_limit_per_file, 0, 1000) do
      params = %{
        path: Args.get(args, :path),
        limit: limit,
        symbol_limit_per_file: symbol_limit
      }

      Structural.dispatch(
        :indexed_outline,
        params,
        context,
        Map.take(params, [:path, :limit, :symbol_limit_per_file])
      )
    end
  end
end
