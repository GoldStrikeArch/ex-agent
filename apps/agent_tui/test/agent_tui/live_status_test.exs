defmodule AgentTui.LiveStatusTest do
  use ExUnit.Case, async: true

  test "tracks active tools and recent tool completion" do
    state = AgentTui.LiveStatus.new(live_enabled: false)

    running =
      AgentTui.LiveStatus.reduce_event(
        state,
        {:tool_started, "tool-1", "read_file", %{"path" => "README.md"}}
      )

    assert IO.iodata_to_binary(AgentTui.LiveStatus.render(running)) =~
             "tools: read_file(tool-1)"

    finished =
      AgentTui.LiveStatus.reduce_event(
        running,
        {:tool_finished, "tool-1", :ok, "read README.md"}
      )

    rendered = IO.iodata_to_binary(AgentTui.LiveStatus.render(finished))
    refute rendered =~ "tools:"
    assert rendered =~ "last tool: read_file :ok read README.md"
  end

  test "tracks active batches and permission state" do
    state =
      AgentTui.LiveStatus.new(live_enabled: false)
      |> AgentTui.LiveStatus.reduce_event({:turn_started, "turn-1"})
      |> AgentTui.LiveStatus.reduce_event({:batch_started, "batch-1", 3})
      |> AgentTui.LiveStatus.reduce_event({:permission_requested, "request-1", "shell: mix test"})

    rendered = IO.iodata_to_binary(AgentTui.LiveStatus.render(state))

    assert rendered =~ "agent: running turn turn-1"
    assert rendered =~ "batches: batch-1 (3 calls)"
    assert rendered =~ "permission: request-1 pending \"shell: mix test\""

    resolved =
      AgentTui.LiveStatus.reduce_event(state, {:permission_resolved, "request-1", "allow"})

    assert IO.iodata_to_binary(AgentTui.LiveStatus.render(resolved)) =~
             "permission: request-1 resolved \"allow\""
  end
end
