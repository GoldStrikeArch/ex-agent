defmodule LLM.Auth.OAuth.Provider do
  @moduledoc """
  Behaviour for OAuth providers that can produce model access tokens.
  """

  alias LLM.Auth.Credential

  @type callback_map :: %{
          optional(:on_auth) => (map() -> any()),
          optional(:on_prompt) => (map() -> String.t() | {:ok, String.t()} | {:error, term()}),
          optional(:on_progress) => (String.t() -> any())
        }

  @doc """
  Runs the provider's interactive login flow and returns credential material.
  """
  @callback login(keyword()) :: {:ok, Credential.t()} | {:error, term()}

  @doc """
  Refreshes an existing provider credential.
  """
  @callback refresh(Credential.t(), keyword()) :: {:ok, Credential.t()} | {:error, term()}

  @doc """
  Extracts a bearer token from a provider credential.
  """
  @callback access_token(Credential.t()) :: {:ok, String.t()} | {:error, term()}
end
