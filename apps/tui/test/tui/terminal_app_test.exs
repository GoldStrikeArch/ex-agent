defmodule Tui.TerminalAppTest do
  use ExUnit.Case, async: true

  alias Tui.TerminalApp

  test "starts an ExRatatui runtime and accepts agent events" do
    {:ok, runtime} = TerminalApp.start_link(test_mode: {40, 10})
    Process.unlink(runtime)

    on_exit(fn ->
      if Process.alive?(runtime), do: TerminalApp.shutdown(runtime)
    end)

    assert %{dimensions: {40, 10}} = ExRatatui.Runtime.snapshot(runtime)

    :ok = TerminalApp.send_event(runtime, {:session_started, %{session_id: "s1"}})

    %{user_state: state} = :sys.get_state(runtime)
    assert state.status.session_id == "s1"
  end
end
