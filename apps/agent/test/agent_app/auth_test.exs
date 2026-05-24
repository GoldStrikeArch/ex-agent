defmodule AgentApp.AuthTest do
  use ExUnit.Case, async: true

  alias AgentApp.Auth
  alias AgentApp.Auth.Storage
  alias LLM.Auth.Credential

  test "resolves a stored credential without refreshing when it is still valid" do
    agent_dir = tmp_dir()
    credential = credential(expires_at: System.system_time(:millisecond) + 120_000)

    assert :ok = Storage.write(:openai_codex, credential, agent_dir: agent_dir)
    assert {:ok, ^credential} = Auth.resolve_credential(:openai_codex, agent_dir: agent_dir)
  end

  test "refreshes and persists an expired credential" do
    agent_dir = tmp_dir()
    expired = credential(expires_at: System.system_time(:millisecond) - 1)
    new_access = jwt("acct_2")
    refreshed = token_response(new_access, "new-refresh")

    token_transport = fn %{grant_type: "refresh_token"} -> refreshed end

    assert :ok = Storage.write(:openai_codex, expired, agent_dir: agent_dir)

    assert {:ok, %Credential{access: ^new_access, refresh: "new-refresh"} = credential} =
             Auth.resolve_credential(:openai_codex,
               agent_dir: agent_dir,
               token_transport: token_transport
             )

    assert {:ok, ^credential} = Storage.read(:openai_codex, agent_dir: agent_dir)
  end

  defp credential(overrides) do
    defaults = %{
      access: jwt("acct_1"),
      refresh: "refresh-token",
      expires_at: System.system_time(:millisecond) + 60_000,
      account_id: "acct_1"
    }

    struct!(Credential, Map.merge(defaults, Map.new(overrides)))
  end

  defp token_response(access, refresh) do
    {:ok,
     %{
       status: 200,
       body: %{
         "access_token" => access,
         "refresh_token" => refresh,
         "expires_in" => 3600
       }
     }}
  end

  defp jwt(account_id) do
    header = %{"alg" => "none"} |> JSON.encode!() |> Base.url_encode64(padding: false)

    payload =
      %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}}
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    header <> "." <> payload <> ".sig"
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-auth-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
