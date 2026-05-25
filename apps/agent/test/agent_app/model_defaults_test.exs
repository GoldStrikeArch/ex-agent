defmodule AgentApp.ModelDefaultsTest do
  use ExUnit.Case, async: true

  alias AgentApp.Auth.Storage
  alias AgentApp.ModelCatalog
  alias AgentApp.ModelDefaults
  alias AgentApp.Settings
  alias LLM.Auth.Credential

  test "persists and restores the default model into unconfigured session options" do
    agent_dir = tmp_dir()

    assert :ok = Storage.write(:openai_codex, credential(), agent_dir: agent_dir)
    assert :ok = ModelCatalog.default() |> ModelDefaults.persist(agent_dir: agent_dir)

    assert {session_opts, nil} = ModelDefaults.apply_to_session_opts([], agent_dir: agent_dir)

    assert session_opts[:model_client] == LLM.ModelClient.OpenAIResponses
    assert session_opts[:permission_mode] == :trusted
    assert session_opts[:model_opts][:model] == "gpt-5.5"
    assert session_opts[:model_opts][:provider] == :openai_codex
    assert session_opts[:model_opts][:auth_provider] == :openai_codex
    assert session_opts[:model_opts][:agent_dir] == agent_dir
    assert is_binary(session_opts[:model_opts][:instructions])
  end

  test "does not override explicitly configured session options" do
    agent_dir = tmp_dir()
    session_opts = [model_client: Core.ModelClient.Mock, model_opts: [model: "test"]]

    assert :ok = ModelCatalog.default() |> ModelDefaults.persist(agent_dir: agent_dir)

    assert {^session_opts, nil} =
             ModelDefaults.apply_to_session_opts(session_opts, agent_dir: agent_dir)
  end

  test "leaves session unconfigured and returns a notice when credentials are missing" do
    agent_dir = tmp_dir()

    assert :ok = ModelCatalog.default() |> ModelDefaults.persist(agent_dir: agent_dir)

    assert {[], notice} = ModelDefaults.apply_to_session_opts([], agent_dir: agent_dir)
    assert notice == "saved model requires openai_codex credentials; run /model to authenticate"
  end

  test "restores legacy Codex gpt-5 settings to the current default model" do
    agent_dir = tmp_dir()

    assert :ok = Storage.write(:openai_codex, credential(), agent_dir: agent_dir)
    assert :ok = Settings.put_default_model(:openai_codex, "gpt-5", agent_dir: agent_dir)

    assert {session_opts, nil} = ModelDefaults.apply_to_session_opts([], agent_dir: agent_dir)
    assert session_opts[:model_opts][:model] == "gpt-5.5"
  end

  defp credential do
    %Credential{
      access: jwt("acct_1"),
      refresh: "refresh-token",
      expires_at: System.system_time(:millisecond) + 120_000,
      account_id: "acct_1"
    }
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
        "agent-model-defaults-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
