defmodule AgentCore.Auth.StorageTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias AgentCore.Auth.Credential
  alias AgentCore.Auth.Storage

  test "writes and reads OAuth credentials with secure file modes" do
    agent_dir = tmp_dir()

    credential = %Credential{
      access: "access-token",
      refresh: "refresh-token",
      expires_at: System.system_time(:millisecond) + 60_000,
      account_id: "acct_1"
    }

    assert :ok = Storage.write(:openai_codex, credential, agent_dir: agent_dir)
    assert {:ok, ^credential} = Storage.read(:openai_codex, agent_dir: agent_dir)

    assert {:ok, dir_stat} = File.stat(agent_dir)
    assert {:ok, file_stat} = Storage.path(agent_dir: agent_dir) |> File.stat()

    assert (dir_stat.mode &&& 0o777) == 0o700
    assert (file_stat.mode &&& 0o777) == 0o600
  end

  test "returns tagged errors for corrupt JSON" do
    agent_dir = tmp_dir()
    File.mkdir_p!(agent_dir)
    File.write!(Storage.path(agent_dir: agent_dir), "{")

    assert {:error, {:corrupt_auth_file, _path, _reason}} =
             Storage.read(:openai_codex, agent_dir: agent_dir)
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-core-auth-storage-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
