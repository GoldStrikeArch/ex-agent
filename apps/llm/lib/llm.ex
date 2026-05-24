defmodule LLM do
  @moduledoc """
  Provider-specific model clients, model metadata, and authentication flows.

  `LLM` adapters implement the pure `Core.ModelClient` behaviour, but durable
  product state such as credential storage belongs to the composing app.
  """
end
