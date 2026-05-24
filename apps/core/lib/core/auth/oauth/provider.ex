defmodule Core.Auth.OAuth.Provider do
  @moduledoc """
  Behaviour for OAuth providers that can produce model access tokens.
  """

  alias Core.Auth.Credential

  @type callback_map :: %{
          optional(:on_auth) => (map() -> any()),
          optional(:on_prompt) => (map() -> String.t() | {:ok, String.t()} | {:error, term()}),
          optional(:on_progress) => (String.t() -> any())
        }

  @callback login(keyword()) :: {:ok, Credential.t()} | {:error, term()}
  @callback refresh(Credential.t(), keyword()) :: {:ok, Credential.t()} | {:error, term()}
  @callback access_token(Credential.t()) :: {:ok, String.t()} | {:error, term()}
end
