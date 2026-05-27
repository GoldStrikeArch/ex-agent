defmodule Core.Tools.Structural.Definitions do
  @moduledoc """
  Finds definition sites for a symbol.

  Stub tool: returns a `:backend_unavailable` result until a real structural
  backend is wired up.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "definitions"

  @impl true
  def description, do: "Find where a symbol is defined."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["symbol"],
      properties: %{symbol: %{type: "string"}}
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, symbol} <- Args.fetch_string(args, :symbol) do
      Structural.dispatch(:definitions, %{symbol: symbol}, context, %{symbol: symbol})
    end
  end
end
