defmodule Structural.Symbol do
  @moduledoc """
  A normalized code symbol produced by `Structural.Parser`.

  The shape matches the C0 structural output contract in `plan.md`: kind, name,
  line and byte ranges, an optional signature, a parent reference, and a short
  preview. The parser fills the source-derived fields; `:path`, `:file_hash`,
  `:id`, and `:parent_id` are assigned later by the index (C1 step 3) once a file
  identity exists.

  `:parent` holds the enclosing symbol's name during parsing (e.g. a function's
  module); the index resolves it to a stable `:parent_id`.
  """

  @type kind ::
          :module
          | :function
          | :private_function
          | :macro
          | :class
          | :method
          | :struct
          | :interface
          | :protocol
          | :impl
          | :other

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          signature: String.t() | nil,
          preview: String.t() | nil,
          parent: String.t() | nil,
          path: Path.t() | nil,
          file_hash: String.t() | nil,
          id: String.t() | nil,
          parent_id: String.t() | nil
        }

  @enforce_keys [:kind, :name, :start_line, :end_line, :start_byte, :end_byte]
  defstruct [
    :kind,
    :name,
    :start_line,
    :end_line,
    :start_byte,
    :end_byte,
    :signature,
    :preview,
    :parent,
    :path,
    :file_hash,
    :id,
    :parent_id
  ]
end
