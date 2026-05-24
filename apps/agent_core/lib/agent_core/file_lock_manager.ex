defmodule AgentCore.FileLockManager do
  @moduledoc """
  Tracks coarse file locks for future write coordination.

  The first skeleton exposes non-blocking acquire/release primitives. Later edit
  tooling can replace this with queued locks while keeping the public contract.
  """

  use GenServer

  defstruct locks: %{}

  @doc """
  Starts the file lock manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  @doc """
  Acquires a lock for `path`.

  Returns `{:error, :locked}` if another process already owns the path.
  """
  @spec acquire(Path.t(), GenServer.server()) :: :ok | {:error, :locked}
  def acquire(path, manager \\ __MODULE__) when is_binary(path) do
    GenServer.call(manager, {:acquire, normalize_path(path), self()})
  end

  @doc """
  Releases a lock held by the calling process.
  """
  @spec release(Path.t(), GenServer.server()) :: :ok
  def release(path, manager \\ __MODULE__) when is_binary(path) do
    GenServer.call(manager, {:release, normalize_path(path), self()})
  end

  @doc """
  Runs `fun` while holding a file lock.
  """
  @spec with_lock(Path.t(), (-> result), GenServer.server()) :: {:ok, result} | {:error, :locked}
        when result: term()
  def with_lock(path, fun, manager \\ __MODULE__) when is_binary(path) and is_function(fun, 0) do
    with :ok <- acquire(path, manager) do
      try do
        {:ok, fun.()}
      after
        release(path, manager)
      end
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:acquire, path, owner}, _from, state) do
    case Map.fetch(state.locks, path) do
      :error ->
        ref = Process.monitor(owner)
        {:reply, :ok, %{state | locks: Map.put(state.locks, path, {owner, ref})}}

      {:ok, _lock} ->
        {:reply, {:error, :locked}, state}
    end
  end

  def handle_call({:release, path, owner}, _from, state) do
    {:reply, :ok, release_owned_lock(state, path, owner)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _reason}, state) do
    locks =
      state.locks
      |> Enum.reject(fn {_path, lock} -> lock == {owner, ref} end)
      |> Map.new()

    {:noreply, %{state | locks: locks}}
  end

  defp release_owned_lock(state, path, owner) do
    case Map.fetch(state.locks, path) do
      {:ok, {^owner, ref}} ->
        Process.demonitor(ref, [:flush])
        %{state | locks: Map.delete(state.locks, path)}

      _other ->
        state
    end
  end

  defp normalize_path(path) do
    path
    |> Path.expand()
    |> Path.absname()
  end
end
