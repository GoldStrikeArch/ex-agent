defmodule AgentTui.GoldenReplayTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("../fixtures/replay", __DIR__)

  test "renders golden replay fixtures" do
    @fixture_dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.each(&assert_fixture/1)
  end

  defp assert_fixture(jsonl_path) do
    expected_path = String.replace_suffix(jsonl_path, ".jsonl", ".txt")

    {:ok, io} = StringIO.open("")
    assert :ok = AgentTui.Replay.render_file(jsonl_path, io: io)
    {_input, output} = StringIO.contents(io)

    assert output == File.read!(expected_path)
  end
end
