defmodule Core.ToolExecutorTest do
  use ExUnit.Case, async: false

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "agent-core-tools-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "README.md"), "# Agent\n")

    File.write!(
      Path.join(workspace, "lib/example.ex"),
      "defmodule Example do\n  def hello, do: :world\nend\n"
    )

    on_exit(fn -> File.rm_rf(workspace) end)

    %{workspace: workspace}
  end

  test "read_file returns content and emits tool events", %{workspace: workspace} do
    :ok = Core.EventBus.subscribe()

    assert {:ok, result} =
             Core.run_tool("read_file", %{"path" => "lib/example.ex"},
               workspace_root: workspace,
               tool_call_id: "tool-read"
             )

    assert result.content =~ "defmodule Example"

    assert_receive {:core_event,
                    {:tool_started, "tool-read", "read_file", %{"path" => "lib/example.ex"}}}

    assert_receive {:core_event, {:tool_output, "tool-read", output}}
    assert output =~ "defmodule Example"
    assert_receive {:core_event, {:tool_finished, "tool-read", :ok, summary}}
    assert summary =~ "read lib/example.ex"
  end

  test "list_files returns sorted direct children", %{workspace: workspace} do
    assert {:ok, result} =
             Core.run_tool("list_files", %{path: "."},
               workspace_root: workspace,
               tool_call_id: "tool-list"
             )

    assert Enum.map(result.entries, & &1.path) == ["README.md", "lib"]
    assert result.output == "README.md\nlib/"
  end

  test "grep returns ripgrep matches", %{workspace: workspace} do
    assert {:ok, result} =
             Core.run_tool("grep", %{pattern: "hello", path: "lib"},
               workspace_root: workspace,
               tool_call_id: "tool-grep"
             )

    assert [%{path: "lib/example.ex", line: 2, column: 7, text: "  def hello, do: :world"}] =
             result.matches

    assert result.summary == "1 match"
  end

  test "unknown tools return structured errors and emit failure events", %{workspace: workspace} do
    :ok = Core.EventBus.subscribe()

    assert {:error, {:unknown_tool, "missing"}} =
             Core.run_tool("missing", %{},
               workspace_root: workspace,
               tool_call_id: "tool-missing"
             )

    assert_receive {:core_event, {:error, :tool, {:unknown_tool, "missing"}}}
    assert_receive {:core_event, {:tool_finished, "tool-missing", :error, summary}}
    assert summary =~ "unknown_tool"
  end
end
