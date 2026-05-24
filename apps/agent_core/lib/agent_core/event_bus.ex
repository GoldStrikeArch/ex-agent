defmodule AgentCore.EventBus do
  @moduledoc """
  Lightweight pub-sub process for agent runtime events.

  Subscribers receive `{:agent_core_event, event}` messages. Events are plain
  tuples matching the protocol in `plan.md`.
  """

  use GenServer

  @type event :: tuple()

  defstruct subscribers: %{}

  @doc """
  Starts the event bus.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  @doc """
  Subscribes the calling process to agent events.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(bus \\ __MODULE__) do
    GenServer.call(bus, {:subscribe, self()})
  end

  @doc """
  Removes the calling process from the event bus.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(bus \\ __MODULE__) do
    GenServer.call(bus, {:unsubscribe, self()})
  end

  @doc """
  Publishes an event to all current subscribers.
  """
  @spec publish(event(), GenServer.server()) :: :ok
  def publish(event, bus \\ __MODULE__) when is_tuple(event) do
    GenServer.cast(bus, {:publish, event})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    next_state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        ref = Process.monitor(pid)
        %{state | subscribers: Map.put(state.subscribers, pid, ref)}
      end

    {:reply, :ok, next_state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    next_state = remove_subscriber(state, pid)
    {:reply, :ok, next_state}
  end

  @impl true
  def handle_cast({:publish, event}, state) do
    Enum.each(Map.keys(state.subscribers), &send(&1, {:agent_core_event, event}))
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.subscribers, pid) do
      {:ok, ^ref} -> {:noreply, remove_subscriber(state, pid)}
      _other -> {:noreply, state}
    end
  end

  defp remove_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, subscribers} ->
        %{state | subscribers: subscribers}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end
end
