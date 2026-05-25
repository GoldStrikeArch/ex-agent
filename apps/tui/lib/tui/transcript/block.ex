defmodule Tui.Transcript.Block do
  @moduledoc """
  Structured transcript block used by the interactive terminal UI.

  Replay and log rendering still use `Tui.TextRenderer`. Blocks are the live UI
  representation that lets streaming messages, tools, permission requests, and
  edit previews update in place.
  """

  @typedoc "Transcript block category."
  @type kind :: :user | :assistant | :tool | :permission | :error | :edit | :system

  @typedoc "Transcript block lifecycle status."
  @type status :: :streaming | :done | :error

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          status: status(),
          title: String.t(),
          body: [String.t()]
        }

  defstruct id: "",
            kind: :system,
            status: :done,
            title: "",
            body: []
end
