defmodule LLM.Model do
  @moduledoc """
  Provider/model configuration used by real model clients.
  """

  @type provider :: :mock | :openai | :openai_codex | atom()

  @type t :: %__MODULE__{
          provider: provider(),
          model: String.t(),
          api: :responses,
          base_url: String.t() | nil,
          headers: %{String.t() => String.t()},
          reasoning_effort: String.t() | nil
        }

  defstruct provider: :openai,
            model: nil,
            api: :responses,
            base_url: nil,
            headers: %{},
            reasoning_effort: nil
end
