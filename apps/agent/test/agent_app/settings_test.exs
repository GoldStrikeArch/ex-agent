defmodule AgentApp.SettingsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias AgentApp.Settings

  test "writes and reads the default model with secure file modes" do
    agent_dir = tmp_dir()

    assert :ok = Settings.put_default_model(:openai_codex, "gpt-5", agent_dir: agent_dir)

    assert {:ok, %{"defaultProvider" => "openai-codex", "defaultModel" => "gpt-5"}} =
             Settings.read(agent_dir: agent_dir)

    assert {:ok, %{provider: "openai-codex", model: "gpt-5"}} =
             Settings.default_model(agent_dir: agent_dir)

    assert {:ok, dir_stat} = File.stat(agent_dir)
    assert {:ok, file_stat} = Settings.path(agent_dir: agent_dir) |> File.stat()

    assert (dir_stat.mode &&& 0o777) == 0o700
    assert (file_stat.mode &&& 0o777) == 0o600
  end

  test "preserves unrelated settings when writing the default model" do
    agent_dir = tmp_dir()
    File.mkdir_p!(agent_dir)
    File.write!(Settings.path(agent_dir: agent_dir), ~s({"theme":"plain"}))

    assert :ok = Settings.put_default_model(:openai_codex, "gpt-5", agent_dir: agent_dir)

    assert {:ok,
            %{
              "theme" => "plain",
              "defaultProvider" => "openai-codex",
              "defaultModel" => "gpt-5"
            }} = Settings.read(agent_dir: agent_dir)
  end

  test "returns tagged errors for corrupt JSON" do
    agent_dir = tmp_dir()
    File.mkdir_p!(agent_dir)
    File.write!(Settings.path(agent_dir: agent_dir), "{")

    assert {:error, {:corrupt_settings_file, _path, _reason}} =
             Settings.read(agent_dir: agent_dir)
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-settings-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
