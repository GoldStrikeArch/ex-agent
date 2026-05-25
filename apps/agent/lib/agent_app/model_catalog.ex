defmodule AgentApp.ModelCatalog do
  @moduledoc """
  Model options exposed by the runnable agent app.
  """

  @type option :: %{
          id: :openai_codex,
          label: String.t(),
          model: String.t(),
          provider: :openai_codex,
          auth_provider: :openai_codex,
          client: module(),
          credential_resolver: function(),
          permission_mode: Core.PermissionPolicy.mode()
        }

  @auth_context_keys [:agent_dir, :path, :token_transport, :token_url]

  @doc """
  Returns every selectable model option.
  """
  @spec all() :: [option()]
  def all, do: [openai_codex()]

  @doc """
  Returns the default model option.
  """
  @spec default() :: option()
  def default, do: openai_codex()

  @doc """
  Finds a catalog option by provider and model.

  Provider values may be atoms from internal callers or strings loaded from
  settings. Unknown providers are not converted to atoms.
  """
  @spec fetch(atom() | String.t(), String.t()) :: {:ok, option()} | {:error, term()}
  def fetch(provider, model) when is_binary(model) do
    case Enum.find(all(), &option_matches?(&1, provider, model)) do
      nil -> {:error, {:unknown_model, provider, model}}
      option -> {:ok, option}
    end
  end

  @doc """
  Converts a catalog option into `Core.configure_model/2` options.
  """
  @spec core_opts(option(), keyword()) :: keyword()
  def core_opts(option, auth_opts \\ []) do
    [
      model_client: option.client,
      model_opts:
        [
          model: option.model,
          provider: option.provider,
          auth_provider: option.auth_provider,
          credential_resolver: option.credential_resolver
        ] ++ auth_context_opts(auth_opts),
      permission_mode: option.permission_mode
    ]
  end

  defp option_matches?(option, provider, model) do
    provider_matches?(option.provider, provider) and option.model == model
  end

  defp provider_matches?(provider, provider_key) when is_atom(provider_key),
    do: provider == provider_key

  defp provider_matches?(provider, provider_key) when is_binary(provider_key),
    do: Atom.to_string(provider) == provider_key

  defp provider_matches?(_provider, _provider_key), do: false

  defp auth_context_opts(auth_opts) do
    Keyword.take(auth_opts, @auth_context_keys)
  end

  defp openai_codex do
    %{
      id: :openai_codex,
      label: "OpenAI subscription",
      model: "gpt-5",
      provider: :openai_codex,
      auth_provider: :openai_codex,
      client: LLM.ModelClient.OpenAIResponses,
      credential_resolver: &AgentApp.Auth.resolve_credential/2,
      permission_mode: :trusted
    }
  end
end
