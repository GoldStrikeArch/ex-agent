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
  Converts a catalog option into `Core.configure_model/2` options.
  """
  @spec core_opts(option()) :: keyword()
  def core_opts(option) do
    [
      model_client: option.client,
      model_opts: [
        model: option.model,
        provider: option.provider,
        auth_provider: option.auth_provider,
        credential_resolver: option.credential_resolver
      ],
      permission_mode: option.permission_mode
    ]
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
