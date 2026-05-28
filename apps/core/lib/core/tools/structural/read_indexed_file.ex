defmodule Core.Tools.Structural.ReadIndexedFile do
  @moduledoc """
  Reads a file that exists in the structural index, with hash validation.
  """

  @behaviour Core.Tool

  alias Core.Structural
  alias Core.Tools.Args

  @impl true
  def name, do: "read_indexed_file"

  @impl true
  def description,
    do: "Read the current contents of an indexed source file, failing if the index is stale."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path"],
      properties: %{
        path: %{type: "string"},
        max_bytes: %{type: "integer", default: 50_000}
      }
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def run(args, context) do
    with {:ok, path} <- Args.fetch_string(args, :path),
         {:ok, max_bytes} <- Args.integer(args, :max_bytes, 50_000, 1, 1_000_000) do
      params = %{path: path, max_bytes: max_bytes}
      Structural.dispatch(:read_indexed_file, params, context, params)
    end
  end
end
