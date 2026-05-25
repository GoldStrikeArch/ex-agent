defmodule AgentApp.ModelDefaults do
  @moduledoc """
  Persists and restores the user's default model selection.

  The selected model is restored only when stored credentials can be resolved.
  Startup never begins an interactive login flow; `/model` remains responsible
  for authentication and changing the persisted default.
  """

  alias AgentApp.ModelCatalog
  alias AgentApp.Settings

  @type restore_notice :: String.t() | nil

  @doc """
  Persists a catalog option as the user's default model.
  """
  @spec persist(ModelCatalog.option(), keyword()) :: :ok | {:error, term()}
  def persist(%{settings_provider: provider, model: model}, opts \\ []) do
    Settings.put_default_model(provider, model, opts)
  end

  @doc """
  Applies the persisted default model to session options when possible.

  Explicitly configured session options are returned unchanged. If settings or
  credentials cannot be used, the original session options are returned with a
  notice that callers may render to the user.
  """
  @spec apply_to_session_opts(keyword(), keyword()) :: {keyword(), restore_notice()}
  def apply_to_session_opts(session_opts, auth_opts \\ []) do
    session_opts
    |> configured_session?()
    |> apply_to_session_opts(session_opts, auth_opts)
  end

  defp apply_to_session_opts(true, session_opts, _auth_opts), do: {session_opts, nil}

  defp apply_to_session_opts(false, session_opts, auth_opts) do
    case restored_model_opts(auth_opts) do
      {:ok, model_opts} -> {Keyword.merge(session_opts, model_opts), nil}
      :none -> {session_opts, nil}
      {:error, reason} -> {session_opts, restore_notice(reason)}
    end
  end

  defp restored_model_opts(auth_opts) do
    with {:ok, %{provider: provider, model: model}} <- Settings.default_model(auth_opts),
         {:ok, option} <- ModelCatalog.fetch(provider, model),
         {:ok, _credential} <- resolve_credential(option, auth_opts) do
      {:ok, ModelCatalog.core_opts(option, auth_opts)}
    end
  end

  defp resolve_credential(option, auth_opts) do
    resolver = Keyword.get(auth_opts, :credential_resolver, &AgentApp.Auth.resolve_credential/2)
    provider = option.auth_provider

    case resolver.(provider, auth_opts) do
      {:error, {:missing_auth_file, _path}} -> {:error, {:missing_credentials, provider}}
      result -> result
    end
  end

  defp restore_notice({:missing_credentials, provider}) do
    "saved model requires #{provider} credentials; run /model to authenticate"
  end

  defp restore_notice({:unknown_model, provider, model}) do
    "saved model is no longer available: #{provider}/#{model}"
  end

  defp restore_notice(reason) do
    "saved model could not be restored: #{inspect(reason)}"
  end

  defp configured_session?(session_opts) do
    Keyword.has_key?(session_opts, :model_client) and
      Keyword.get(session_opts, :model_client) != Core.ModelClient.Unconfigured
  end
end
