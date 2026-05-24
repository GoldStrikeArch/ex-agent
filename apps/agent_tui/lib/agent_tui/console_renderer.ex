defmodule AgentTui.ConsoleRenderer do
  @moduledoc """
  Append-only console renderer subscribed to `AgentCore.EventBus`.
  """

  use GenServer

  defstruct io: :stdio

  @doc """
  Starts the console renderer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    :ok = AgentCore.EventBus.subscribe()
    {:ok, %__MODULE__{io: Keyword.get(opts, :io, :stdio)}}
  end

  @impl true
  def handle_info({:agent_core_event, event}, state) do
    IO.write(state.io, AgentTui.TextRenderer.render(event))
    {:noreply, state}
  end
end
