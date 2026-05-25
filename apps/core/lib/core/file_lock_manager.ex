defmodule Core.FileLockManager do
  @moduledoc """
  Tracks coarse file locks for write coordination.

  The GenServer-backed functions coordinate locks inside the current VM. The
  lock-file helper coordinates durable files across separate OS processes.
  """

  use GenServer

  defstruct locks: %{}

  @default_lock_stale_after_ms 30_000
  @default_lock_retry_sleep_ms 10
  @default_lock_retry_count 100

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

  @doc """
  Runs `fun` while holding a sibling lock file.

  Unlike the GenServer-backed `with_lock/3`, this lock coordinates separate OS
  processes by creating `path <> ".lock"` with exclusive file creation. Stale
  lock files are removed after the configured stale timeout.
  """
  @spec with_lock_file(Path.t(), (-> result), keyword()) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_lock_file(path, fun, opts \\ [])
      when is_binary(path) and is_function(fun, 0) and is_list(opts) do
    lock_path = Keyword.get(opts, :lock_path, path <> ".lock")

    with :ok <- prepare_lock_dir(lock_path),
         {:ok, io} <- acquire_file_lock(lock_path, retry_count(opts), opts) do
      try do
        {:ok, fun.()}
      after
        File.close(io)
        File.rm(lock_path)
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

  defp prepare_lock_dir(lock_path) do
    case File.mkdir_p(Path.dirname(lock_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_lock_failed, lock_path, reason}}
    end
  end

  defp acquire_file_lock(lock_path, attempts_left, opts) when attempts_left > 0 do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, "#{inspect(self())}\n")
        {:ok, io}

      {:error, :eexist} ->
        remove_stale_file_lock(lock_path, stale_after_ms(opts))
        Process.sleep(retry_sleep_ms(opts))
        acquire_file_lock(lock_path, attempts_left - 1, opts)

      {:error, reason} ->
        {:error, {:file_lock_failed, lock_path, reason}}
    end
  end

  defp acquire_file_lock(lock_path, _attempts_left, _opts),
    do: {:error, {:file_lock_timeout, lock_path}}

  defp remove_stale_file_lock(lock_path, stale_after_ms) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        lock_age_ms = System.system_time(:millisecond) - mtime * 1000
        if lock_age_ms > stale_after_ms, do: File.rm(lock_path), else: :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp retry_count(opts), do: Keyword.get(opts, :retry_count, @default_lock_retry_count)
  defp retry_sleep_ms(opts), do: Keyword.get(opts, :retry_sleep_ms, @default_lock_retry_sleep_ms)
  defp stale_after_ms(opts), do: Keyword.get(opts, :stale_after_ms, @default_lock_stale_after_ms)
end
