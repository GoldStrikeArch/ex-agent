defmodule Network.WebSocket.SessionPool do
  @moduledoc """
  Registry for session-keyed reusable WebSocket connections.

  The pool keeps provider-opaque metadata with each live connection. Callers own
  metadata shape and update it only after a successful stream.
  """

  use GenServer

  @type cache_key :: term()

  @doc """
  Starts the session pool.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Returns a reusable connection process for `cache_key`.
  """
  @spec checkout(cache_key()) :: {:ok, pid()} | {:error, term()}
  def checkout(cache_key) do
    GenServer.call(__MODULE__, {:checkout, cache_key})
  end

  @doc """
  Returns opaque metadata stored by the session connection, if present.
  """
  @spec metadata(cache_key()) :: term() | nil
  def metadata(cache_key) do
    GenServer.call(__MODULE__, {:metadata, cache_key})
  end

  @doc """
  Closes and forgets the cached connection for `cache_key`.
  """
  @spec close(cache_key()) :: :ok
  def close(cache_key) do
    GenServer.call(__MODULE__, {:close, cache_key})
  end

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, monitors: %{}}}

  @impl true
  def handle_call({:checkout, cache_key}, _from, state) do
    case live_entry(state, cache_key) do
      {:ok, pid, state} ->
        {:reply, {:ok, pid}, state}

      {:error, state} ->
        start_connection(cache_key, state)
    end
  end

  def handle_call({:metadata, cache_key}, _from, state) do
    case live_entry(state, cache_key) do
      {:ok, pid, state} -> {:reply, Network.WebSocket.Connection.metadata(pid), state}
      {:error, state} -> {:reply, nil, state}
    end
  end

  def handle_call({:close, cache_key}, _from, state) do
    state =
      case live_entry(state, cache_key) do
        {:ok, pid, state} ->
          Network.WebSocket.Connection.close(pid)
          drop_entry(state, cache_key, pid)

        {:error, state} ->
          state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, cache_key} -> {:noreply, drop_entry(state, cache_key, pid, ref)}
      :error -> {:noreply, state}
    end
  end

  defp live_entry(state, cache_key) do
    case Map.fetch(state.entries, cache_key) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:ok, pid, state},
          else: {:error, drop_entry(state, cache_key, pid)}

      _entry ->
        {:error, state}
    end
  end

  defp start_connection(cache_key, state) do
    child = {Network.WebSocket.Connection, cache_key: cache_key}

    case DynamicSupervisor.start_child(Network.WebSocket.ConnectionSupervisor, child) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state = %{
          state
          | entries: Map.put(state.entries, cache_key, pid),
            monitors: Map.put(state.monitors, ref, cache_key)
        }

        {:reply, {:ok, pid}, state}

      {:error, reason} ->
        {:reply, {:error, {:network_websocket_pool_unavailable, reason}}, state}
    end
  end

  defp drop_entry(state, cache_key, pid) do
    {ref, monitors} = pop_monitor(state.monitors, cache_key)

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    %{state | entries: reject_pid(state.entries, cache_key, pid), monitors: monitors}
  end

  defp drop_entry(state, cache_key, pid, ref) do
    %{
      state
      | entries: reject_pid(state.entries, cache_key, pid),
        monitors: Map.delete(state.monitors, ref)
    }
  end

  defp pop_monitor(monitors, cache_key) do
    Enum.reduce_while(monitors, {nil, monitors}, fn
      {ref, ^cache_key}, {_found, acc} -> {:halt, {ref, Map.delete(acc, ref)}}
      _entry, acc -> {:cont, acc}
    end)
  end

  defp reject_pid(entries, cache_key, pid) do
    case Map.fetch(entries, cache_key) do
      {:ok, ^pid} -> Map.delete(entries, cache_key)
      _entry -> entries
    end
  end
end
