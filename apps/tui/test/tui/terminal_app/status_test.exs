defmodule Tui.TerminalApp.StatusTest do
  use ExUnit.Case, async: true

  alias Tui.TerminalApp.Status

  test "tracks active tools and recent tool completion" do
    state = Status.new()

    running =
      Status.reduce_event(
        state,
        {:tool_started, "tool-1", "read_file", %{"path" => "README.md"}}
      )

    assert Status.summary_line(running) =~ "tools 1"

    finished =
      Status.reduce_event(
        running,
        {:tool_finished, "tool-1", :ok, "read README.md"}
      )

    rendered = Enum.join(Status.panel_lines(finished), "\n")
    refute rendered =~ "tools: read_file(tool-1)"
    assert rendered =~ "last tool: read_file :ok read README.md"
  end

  test "renders configured model and thinking level" do
    state =
      Status.new()
      |> Status.reduce_event(
        {:model_configured,
         %{label: "OpenAI subscription", model: "gpt-5.5", thinking_level: "high"}}
      )

    assert Status.summary_line(state) =~ "model gpt-5.5"
    assert Status.summary_line(state) =~ "thinking high"

    rendered = Enum.join(Status.panel_lines(state), "\n")
    assert rendered =~ "model: OpenAI subscription (gpt-5.5)"
    assert rendered =~ "thinking: high"
  end

  test "tracks active batches and permission state" do
    state =
      Status.new()
      |> Status.reduce_event({:turn_started, "turn-1"})
      |> Status.reduce_event({:batch_started, "batch-1", 3})
      |> Status.reduce_event({:permission_requested, "request-1", "shell: mix test"})

    rendered = Enum.join(Status.panel_lines(state), "\n")

    assert rendered =~ "turn turn-1"
    assert rendered =~ "batches: batch-1 (3 calls)"
    assert rendered =~ "permission: request-1 pending \"shell: mix test\""

    resolved = Status.reduce_event(state, {:permission_resolved, "request-1", "allow"})

    assert Enum.join(Status.panel_lines(resolved), "\n") =~
             "permission: request-1 resolved \"allow\""
  end
end
