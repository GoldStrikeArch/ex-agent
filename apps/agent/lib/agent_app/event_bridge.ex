defmodule AgentApp.EventBridge do
  @moduledoc """
  Forwards `Core.EventBus` events into a `Tui.TerminalApp` runtime.
  """

  use GenServer

  defstruct runtime: nil

  @type t :: %__MODULE__{
          runtime: GenServer.server()
        }

  @doc """
  Starts an event bridge for one terminal UI runtime.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    :ok = Core.EventBus.subscribe()
    {:ok, %__MODULE__{runtime: Keyword.fetch!(opts, :runtime)}}
  end

  @impl true
  def handle_info({:core_event, event}, state) do
    Tui.TerminalApp.send_event(state.runtime, event)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Core.EventBus.unsubscribe()
    :ok
  catch
    :exit, _reason -> :ok
  end
end
