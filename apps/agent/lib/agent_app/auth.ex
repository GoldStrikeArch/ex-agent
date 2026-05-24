defmodule AgentApp.Auth do
  @moduledoc """
  Product-level authentication orchestration.

  Provider modules know how to obtain and refresh credentials. This module owns
  durable storage and refresh persistence for the runnable agent app.
  """

  alias AgentApp.Auth.Storage
  alias LLM.Auth.Credential
  alias LLM.Auth.OAuth.OpenAICodex

  @doc """
  Runs a provider login flow and stores the returned credential.
  """
  @spec login(:openai_codex, keyword()) :: {:ok, Credential.t()} | {:error, term()}
  def login(:openai_codex, opts \\ []) do
    with {:ok, credential} <- OpenAICodex.login(opts),
         :ok <- Storage.write(:openai_codex, credential, opts) do
      {:ok, credential}
    end
  end

  @doc """
  Reads a stored credential and refreshes it when expired.
  """
  @spec resolve_credential(:openai_codex, keyword()) :: {:ok, Credential.t()} | {:error, term()}
  def resolve_credential(:openai_codex, opts \\ []) do
    with {:ok, credential} <- Storage.read(:openai_codex, opts) do
      refresh_if_expired(:openai_codex, credential, opts)
    end
  end

  @doc """
  Refreshes and persists a provider credential.
  """
  @spec refresh(:openai_codex, Credential.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, term()}
  def refresh(:openai_codex, %Credential{} = credential, opts \\ []) do
    with {:ok, refreshed} <- OpenAICodex.refresh(credential, opts),
         :ok <- Storage.write(:openai_codex, refreshed, opts) do
      {:ok, refreshed}
    end
  end

  defp refresh_if_expired(provider, %Credential{} = credential, opts) do
    if Credential.expired?(credential) do
      refresh(provider, credential, opts)
    else
      {:ok, credential}
    end
  end
end
