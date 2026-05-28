defmodule Core.Tools.Structural.IndexedFiles do
  @moduledoc """
  Lists indexed source files, optionally scoped to a workspace path.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "indexed_files"

  @impl true
  def description,
    do: "List indexed source files under an optional workspace path before outlining files."

  @impl true
  def schema do
    %{
      type: "object",
      required: [],
      properties: %{
        path: %{type: "string"},
        limit: %{type: "integer", default: 200}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, limit} <- Args.optional_integer(args, :limit, 1, 1000) do
      params = %{path: Args.get(args, :path), limit: limit}
      details = Map.take(params, [:path, :limit])
      Structural.dispatch(:indexed_files, params, context, details)
    end
  end
end
