defmodule Core.Tools.Structural.IndexStatus do
  @moduledoc """
  Reports structural index freshness and coverage.

  Stub tool: returns a `:backend_unavailable` result until a real structural
  backend is wired up.
  """

  @behaviour Core.Tool

  alias Core.Structural

  @impl true
  def name, do: "index_status"

  @impl true
  def description, do: "Report whether the structural index exists and how fresh it is."

  @impl true
  def schema do
    %{type: "object", required: [], properties: %{}}
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(_args, context) do
    Structural.dispatch(:index_status, %{}, context)
  end
end
