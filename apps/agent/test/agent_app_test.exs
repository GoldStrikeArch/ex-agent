defmodule AgentAppTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  test "runs replay through the application CLI" do
    path =
      Path.expand("../../tui/test/fixtures/replay/streaming.jsonl", __DIR__)

    output =
      capture_io(fn ->
        assert :ok = AgentApp.CLI.main(["--replay", path])
      end)

    assert output == """
           session started session-stream
           user> hello
           assistant> hello, world
           """
  end
end
