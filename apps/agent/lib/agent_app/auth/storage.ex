defmodule AgentApp.Auth.Storage do
  @moduledoc """
  File-backed credential storage for provider auth.

  Credentials live in `$ELIXIR_AGENT_DIR/auth.json`, defaulting to
  `~/.elixir-agent/agent/auth.json`. Writes are protected by a sibling lock file
  to avoid concurrent refresh races.
  """

  alias LLM.Auth.Credential

  @lock_stale_after_ms 30_000
  @lock_retry_sleep_ms 10
  @lock_retry_count 100

  @doc """
  Reads a provider credential.
  """
  @spec read(atom(), keyword()) :: {:ok, Credential.t()} | {:error, term()}
  def read(provider, opts \\ []) when is_atom(provider) do
    with {:ok, records} <- read_all(opts) do
      case Map.get(records, provider_key(provider)) do
        nil -> {:error, {:missing_credentials, provider}}
        record -> Credential.from_map(record)
      end
    end
  end

  @doc """
  Writes a provider credential.
  """
  @spec write(atom(), Credential.t(), keyword()) :: :ok | {:error, term()}
  def write(provider, %Credential{} = credential, opts \\ []) when is_atom(provider) do
    with_lock(opts, fn ->
      with {:ok, records} <- writable_records(opts) do
        records
        |> Map.put(provider_key(provider), Credential.to_map(credential))
        |> write_all(opts)
      end
    end)
  end

  @doc """
  Resolves the configured agent directory.
  """
  @spec agent_dir(keyword()) :: Path.t()
  def agent_dir(opts \\ []) do
    Keyword.get(opts, :agent_dir) ||
      System.get_env("ELIXIR_AGENT_DIR") ||
      Path.join([System.user_home!(), ".elixir-agent", "agent"])
  end

  @doc """
  Resolves the auth JSON file path.
  """
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) do
    Keyword.get(opts, :path) || Path.join(agent_dir(opts), "auth.json")
  end

  defp read_all(opts) do
    path = path(opts)

    path
    |> File.read()
    |> decode_auth_file(path)
  end

  defp writable_records(opts) do
    case read_all(opts) do
      {:ok, records} -> {:ok, records}
      {:error, {:missing_auth_file, _path}} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_all(records, opts) do
    path = path(opts)
    tmp_path = path <> ".tmp"

    try do
      with :ok <- prepare_auth_dir(path),
           :ok <- write_tmp_file(tmp_path, records),
           :ok <- replace_auth_file(tmp_path, path) do
        :ok
      else
        {:error, reason} -> {:error, {:write_auth_file_failed, path, reason}}
      end
    after
      File.rm(tmp_path)
    end
  end

  defp decode_auth_file({:ok, content}, path) do
    case JSON.decode(content) do
      {:ok, records} when is_map(records) -> {:ok, records}
      {:ok, decoded} -> {:error, {:invalid_auth_file, decoded}}
      {:error, reason} -> {:error, {:corrupt_auth_file, path, reason}}
    end
  end

  defp decode_auth_file({:error, :enoent}, path), do: {:error, {:missing_auth_file, path}}

  defp decode_auth_file({:error, reason}, path),
    do: {:error, {:read_auth_file_failed, path, reason}}

  defp prepare_auth_dir(path) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir) do
      chmod(dir, 0o700)
    end
  end

  defp write_tmp_file(tmp_path, records) do
    with :ok <- File.write(tmp_path, JSON.encode!(records), [:binary]) do
      chmod(tmp_path, 0o600)
    end
  end

  defp replace_auth_file(tmp_path, path) do
    with :ok <- File.rename(tmp_path, path) do
      chmod(path, 0o600)
    end
  end

  defp with_lock(opts, fun) when is_function(fun, 0) do
    lock_path = path(opts) <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))

    case acquire_lock(lock_path, @lock_retry_count) do
      {:ok, io} ->
        try do
          fun.()
        after
          File.close(io)
          File.rm(lock_path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp acquire_lock(lock_path, attempts_left) when attempts_left > 0 do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, "#{inspect(self())}\n")
        {:ok, io}

      {:error, :eexist} ->
        remove_stale_lock(lock_path)
        Process.sleep(@lock_retry_sleep_ms)
        acquire_lock(lock_path, attempts_left - 1)

      {:error, reason} ->
        {:error, {:auth_lock_failed, lock_path, reason}}
    end
  end

  defp acquire_lock(lock_path, 0), do: {:error, {:auth_lock_timeout, lock_path}}

  defp remove_stale_lock(lock_path) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        age_ms = System.system_time(:millisecond) - mtime * 1000
        if age_ms > @lock_stale_after_ms, do: File.rm(lock_path), else: :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_key(provider), do: Atom.to_string(provider)
end
