defmodule Core.Auth.OAuth.PKCE do
  @moduledoc """
  PKCE verifier/challenge generation for OAuth authorization-code flows.
  """

  @type pair :: %{verifier: String.t(), challenge: String.t()}

  @doc """
  Generates a base64url verifier and SHA-256 challenge.
  """
  @spec generate() :: pair()
  def generate do
    verifier =
      32
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    challenge =
      :sha256
      |> :crypto.hash(verifier)
      |> Base.url_encode64(padding: false)

    %{verifier: verifier, challenge: challenge}
  end
end
