defmodule Structural do
  @moduledoc """
  Tree-sitter backed structural code intelligence for the agent.

  This app provides the real implementation of `Core.Structural.Backend`: a
  Tree-sitter parser (a Rustler NIF), a SQLite-backed symbol index, and a backend
  module that maps the structural tools (`ast_outline`, `symbol_search`,
  `fetch_node`, …) onto the index.

  Core defines the behaviour and keeps `Core.Structural.Backend.Unavailable` as
  its default. Sessions opt into this backend by setting `:structural_backend` to
  `Structural.Backend`; until the NIF and index are wired up,
  `Structural.Backend.available?/0` reports `false` and operations degrade to the
  same visible `:backend_unavailable` results as the default.
  """
end
