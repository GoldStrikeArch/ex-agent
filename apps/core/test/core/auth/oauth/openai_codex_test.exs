defmodule Core.Auth.OAuth.OpenAICodexTest do
  use ExUnit.Case, async: true

  alias Core.Auth.Credential
  alias Core.Auth.OAuth.OpenAICodex
  alias Core.Auth.OAuth.PKCE

  test "generates PKCE verifier and challenge" do
    assert %{verifier: verifier, challenge: challenge} = PKCE.generate()
    assert byte_size(verifier) >= 43
    assert byte_size(challenge) >= 43
    refute verifier =~ "="
    refute challenge =~ "="
  end

  test "parses authorization code inputs" do
    assert OpenAICodex.parse_authorization_input("abc123") == %{code: "abc123"}

    assert OpenAICodex.parse_authorization_input("abc123#state456") == %{
             code: "abc123",
             state: "state456"
           }

    assert OpenAICodex.parse_authorization_input(
             "http://localhost:1455/auth/callback?code=abc123&state=state456"
           ) == %{code: "abc123", state: "state456"}
  end

  test "exchanges authorization codes into credentials" do
    parent = self()
    jwt = jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_1"}})

    token_transport = fn params ->
      send(parent, {:token_params, params})

      {:ok,
       %{
         status: 200,
         body: %{
           "access_token" => jwt,
           "refresh_token" => "refresh-token",
           "expires_in" => 3600
         }
       }}
    end

    assert {:ok, %Credential{} = credential} =
             OpenAICodex.exchange_code("code-1", "verifier-1", token_transport: token_transport)

    assert credential.access == jwt
    assert credential.refresh == "refresh-token"
    assert credential.account_id == "acct_1"
    assert credential.expires_at > System.system_time(:millisecond)

    assert_receive {:token_params,
                    %{
                      grant_type: "authorization_code",
                      code: "code-1",
                      code_verifier: "verifier-1"
                    }}
  end

  defp jwt(payload) do
    header = %{"alg" => "none"} |> JSON.encode!() |> Base.url_encode64(padding: false)
    payload = payload |> JSON.encode!() |> Base.url_encode64(padding: false)
    header <> "." <> payload <> ".sig"
  end
end
