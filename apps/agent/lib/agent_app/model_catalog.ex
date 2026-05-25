defmodule AgentApp.ModelCatalog do
  @moduledoc """
  Model options exposed by the runnable agent app.
  """

  @type option :: %{
          id: :openai_codex,
          label: String.t(),
          model: String.t(),
          provider: :openai_codex,
          settings_provider: String.t(),
          auth_provider: :openai_codex,
          client: module(),
          credential_resolver: function(),
          instructions: String.t(),
          text_verbosity: String.t(),
          permission_mode: Core.PermissionPolicy.mode()
        }

  @auth_context_keys [:agent_dir, :path, :token_transport, :token_url]
  @default_instructions """
  You are a coding agent running in a local workspace.
  Inspect before editing.
  Prefer batching independent read-only tool calls.
  Use shell commands only when they directly help the task.
  After edits, run focused validation when possible.
  Keep responses concise and grounded in observed files and command output.
  """

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
    model = canonical_model(provider, model)

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
          credential_resolver: option.credential_resolver,
          instructions: option.instructions,
          text_verbosity: option.text_verbosity
        ] ++ auth_context_opts(auth_opts),
      permission_mode: option.permission_mode
    ]
  end

  defp option_matches?(option, provider, model) do
    provider_matches?(option.provider, provider) and option.model == model
  end

  defp provider_matches?(provider, provider_key) do
    provider_key(provider) == provider_key(provider_key)
  end

  defp provider_key(:openai_codex), do: "openai-codex"
  defp provider_key(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_key(provider) when is_binary(provider), do: String.replace(provider, "_", "-")
  defp provider_key(_provider), do: nil

  defp canonical_model(provider, "gpt-5") do
    case provider_key(provider) do
      "openai-codex" -> "gpt-5.5"
      _provider -> "gpt-5"
    end
  end

  defp canonical_model(_provider, model), do: model

  defp auth_context_opts(auth_opts) do
    Keyword.take(auth_opts, @auth_context_keys)
  end

  defp openai_codex do
    %{
      id: :openai_codex,
      label: "OpenAI subscription",
      model: "gpt-5.5",
      provider: :openai_codex,
      settings_provider: "openai-codex",
      auth_provider: :openai_codex,
      client: LLM.ModelClient.OpenAIResponses,
      credential_resolver: &AgentApp.Auth.resolve_credential/2,
      instructions: String.trim(@default_instructions),
      text_verbosity: "low",
      permission_mode: :trusted
    }
  end
end
