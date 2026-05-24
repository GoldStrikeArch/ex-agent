defmodule AgentTui.TerminalApp.EventBridge do
  @moduledoc """
  Forwards `AgentCore.EventBus` events into a TermUI runtime message queue.
  """

  use GenServer

  defstruct runtime: nil

  @type t :: %__MODULE__{
          runtime: GenServer.server()
        }

  @doc """
  Starts an event bridge for one TermUI runtime.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    :ok = AgentCore.EventBus.subscribe()
    {:ok, %__MODULE__{runtime: Keyword.fetch!(opts, :runtime)}}
  end

  @impl true
  def handle_info({:agent_core_event, event}, state) do
    TermUI.Runtime.send_message(state.runtime, :root, {:agent_core_event, event})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    AgentCore.EventBus.unsubscribe()
    :ok
  catch
    :exit, _reason -> :ok
  end
end
