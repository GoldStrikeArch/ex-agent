defmodule Core.Tools.Structural.AstOutline do
  @moduledoc """
  Returns a compact structural outline of a file's top-level symbols.

  Stub tool: returns a `:backend_unavailable` result until a real structural
  backend is wired up.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "ast_outline"

  @impl true
  def description,
    do: "List a file's symbols, kinds, and line ranges before reading the whole file."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path"],
      properties: %{path: %{type: "string"}}
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, path} <- Args.fetch_string(args, :path) do
      Structural.dispatch(:ast_outline, %{path: path}, context, %{path: path})
    end
  end
end
