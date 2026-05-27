defmodule Core.Tools.Structural.IndexRepo do
  @moduledoc """
  Builds or refreshes the structural index for the workspace.

  Stub tool: returns a `:backend_unavailable` result until a real structural
  backend is wired up.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "index_repo"

  @impl true
  def description,
    do: "Build or refresh the structural code index for the workspace before structural queries."

  @impl true
  def schema do
    %{
      type: "object",
      required: [],
      properties: %{
        path: %{type: "string", default: "."},
        languages: %{type: "array", items: %{type: "string"}}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    path = Args.get(args, :path, ".")
    Structural.dispatch(:index_repo, %{path: path}, context, %{path: path})
  end
end
