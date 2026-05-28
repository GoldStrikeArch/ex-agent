defmodule Core.Structural.Backend do
  @moduledoc """
  Behaviour for structural (Tree-sitter style) code intelligence backends.

  The behaviour is defined before any real backend exists so the model loop and
  tool schemas are stable. The default backend is
  `Core.Structural.Backend.Unavailable`, which reports that no structural index
  is wired up yet. A real backend (parser, index store, query engine) can be
  slotted in later without changing tool schemas or the model contract.

  Operations return one of:

    * `{:ok, payload}` - a normalized structural result map.
    * `{:error, reason}` - a tagged backend failure.
    * `:unavailable` - no backend is configured; tools surface this as a
      successful `:backend_unavailable` result rather than a tool error.
  """

  @typedoc """
  Structural operation requested by a tool.
  """
  @type operation ::
          :index_repo
          | :index_status
          | :indexed_files
          | :indexed_outline
          | :ast_outline
          | :symbol_search
          | :ast_query
          | :read_indexed_file
          | :fetch_node
          | :definitions
          | :callers

  @type result :: {:ok, map()} | {:error, term()} | :unavailable

  @doc """
  Reports whether the backend can currently serve structural queries.
  """
  @callback available?() :: boolean()

  @doc """
  Runs a validated structural `operation` with normalized `args`.

  Implementations receive arguments that tools have already validated. They must
  return `{:ok, payload}`, `{:error, reason}`, or `:unavailable`.
  """
  @callback run(operation(), map(), Core.Tool.context()) :: result()
end
