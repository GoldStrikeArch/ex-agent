defmodule AgentApp.Settings do
  @moduledoc """
  File-backed user settings for the runnable agent app.

  Settings live in `$ELIXIR_AGENT_DIR/settings.json`, defaulting to
  `~/.elixir-agent/agent/settings.json`. Model selection uses PI-compatible
  `defaultProvider` and `defaultModel` fields so auth and user preferences stay
  as separate files.
  """

  alias AgentApp.Auth.Storage
  alias Core.FileLockManager

  @type settings :: %{optional(String.t()) => term()}
  @type default_model :: %{provider: String.t(), model: String.t()}

  @doc """
  Reads all user settings.

  A missing settings file returns an empty settings map. Corrupt JSON and
  non-object JSON values are returned as tagged errors.
  """
  @spec read(keyword()) :: {:ok, settings()} | {:error, term()}
  def read(opts \\ []) do
    path = path(opts)

    path
    |> File.read()
    |> decode_settings_file(path)
  end

  @doc """
  Returns the persisted default provider/model pair when both fields are set.
  """
  @spec default_model(keyword()) :: {:ok, default_model()} | :none | {:error, term()}
  def default_model(opts \\ []) do
    with {:ok, settings} <- read(opts) do
      default_model_from_settings(settings)
    end
  end

  @doc """
  Persists the default provider/model pair.

  Unknown settings already present in the file are preserved.
  """
  @spec put_default_model(atom() | String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def put_default_model(provider, model, opts \\ []) when is_binary(model) do
    with {:ok, result} <-
           FileLockManager.with_lock_file(path(opts), fn ->
             put_default_model_locked(provider, model, opts)
           end) do
      result
    end
  end

  @doc """
  Resolves the settings JSON file path.
  """
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []) do
    Keyword.get(opts, :settings_path) || Path.join(Storage.agent_dir(opts), "settings.json")
  end

  defp default_model_from_settings(%{
         "defaultProvider" => provider,
         "defaultModel" => model
       })
       when is_binary(provider) and is_binary(model) and provider != "" and model != "" do
    {:ok, %{provider: provider, model: model}}
  end

  defp default_model_from_settings(_settings), do: :none

  defp decode_settings_file({:ok, content}, path) do
    case JSON.decode(content) do
      {:ok, settings} when is_map(settings) -> {:ok, settings}
      {:ok, decoded} -> {:error, {:invalid_settings_file, decoded}}
      {:error, reason} -> {:error, {:corrupt_settings_file, path, reason}}
    end
  end

  defp decode_settings_file({:error, :enoent}, _path), do: {:ok, %{}}

  defp decode_settings_file({:error, reason}, path),
    do: {:error, {:read_settings_file_failed, path, reason}}

  defp put_default_model_locked(provider, model, opts) do
    with {:ok, settings} <- read(opts) do
      settings
      |> Map.put("defaultProvider", provider_key(provider))
      |> Map.put("defaultModel", model)
      |> write_all(opts)
    end
  end

  defp write_all(settings, opts) do
    path = path(opts)
    tmp_path = path <> ".tmp"

    try do
      with :ok <- prepare_settings_dir(path),
           :ok <- write_tmp_file(tmp_path, settings),
           :ok <- replace_settings_file(tmp_path, path) do
        :ok
      else
        {:error, reason} -> {:error, {:write_settings_file_failed, path, reason}}
      end
    after
      File.rm(tmp_path)
    end
  end

  defp prepare_settings_dir(path) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir) do
      chmod(dir, 0o700)
    end
  end

  defp write_tmp_file(tmp_path, settings) do
    content = JSON.encode!(settings) <> "\n"

    with :ok <- File.write(tmp_path, content, [:binary]) do
      chmod(tmp_path, 0o600)
    end
  end

  defp replace_settings_file(tmp_path, path) do
    with :ok <- File.rename(tmp_path, path) do
      chmod(path, 0o600)
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_key(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_key(provider) when is_binary(provider), do: provider
end
