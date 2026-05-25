defmodule Core.ModelClient.Unconfigured do
  @moduledoc """
  Model client used when an app wants explicit model setup before chatting.
  """

  @behaviour Core.ModelClient

  @impl true
  def stream_chat(_messages, _tools, _opts, event_sink) when is_function(event_sink, 1) do
    {:error, :model_not_configured}
  end

  @impl true
  def complete_chat(_messages, _tools, _opts), do: {:error, :model_not_configured}
end
