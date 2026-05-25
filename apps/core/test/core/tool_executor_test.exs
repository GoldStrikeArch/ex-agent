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

  test "read only permission denies mutating and shell tools", %{workspace: workspace} do
    assert {:error, {:permission_denied, :read_only, "shell", :shell}} =
             Core.run_tool("shell", %{"command" => "pwd"}, workspace_root: workspace)

    assert {:error, {:permission_denied, :read_only, "write_file", :write}} =
             Core.run_tool("write_file", %{"path" => "out.txt", "content" => "x"},
               workspace_root: workspace
             )

    assert {:error, {:permission_denied, :read_only, "edit_file", :write}} =
             Core.run_tool(
               "edit_file",
               %{"path" => "README.md", "search" => "Agent", "replace" => "Core"},
               workspace_root: workspace
             )
  end

  test "shell runs inside the workspace and keeps nonzero exits as results", %{
    workspace: workspace
  } do
    assert {:ok, result} =
             Core.run_tool(
               "shell",
               %{"command" => "pwd && printf '\\nresult'"},
               workspace_root: workspace,
               permission_mode: :trusted
             )

    assert result.exit_status == 0
    assert result.output =~ workspace
    assert result.output =~ "result"

    assert {:ok, result} =
             Core.run_tool(
               "shell",
               %{"command" => "printf failed; exit 7"},
               workspace_root: workspace,
               permission_mode: :trusted
             )

    assert result.exit_status == 7
    assert result.output == "failed"
  end

  test "shell truncates captured output", %{workspace: workspace} do
    assert {:ok, result} =
             Core.run_tool(
               "shell",
               %{"command" => "printf abcdef", "max_output_bytes" => 3},
               workspace_root: workspace,
               permission_mode: :trusted
             )

    assert result.output == "abc"
    assert result.truncated
  end

  test "write_file writes inside the workspace and creates directories when requested", %{
    workspace: workspace
  } do
    assert {:error, {:write_file_failed, "nested/out.txt", :enoent}} =
             Core.run_tool(
               "write_file",
               %{"path" => "nested/out.txt", "content" => "hello"},
               workspace_root: workspace,
               permission_mode: :trusted
             )

    assert {:ok, result} =
             Core.run_tool(
               "write_file",
               %{"path" => "nested/out.txt", "content" => "hello", "create_dirs" => true},
               workspace_root: workspace,
               permission_mode: :trusted
             )

    assert result.bytes_written == 5
    assert File.read!(Path.join(workspace, "nested/out.txt")) == "hello"
  end

  test "write_file rejects paths outside the workspace", %{workspace: workspace} do
    assert {:error, {:path_outside_workspace, "../outside.txt"}} =
             Core.run_tool(
               "write_file",
               %{"path" => "../outside.txt", "content" => "nope"},
               workspace_root: workspace,
               permission_mode: :trusted
             )
  end

  test "edit_file replaces first or all occurrences and validates counts", %{workspace: workspace} do
    path = Path.join(workspace, "replace.txt")
    File.write!(path, "one fish one fish")

    assert {:ok, %{replacements: 1}} =
             Core.run_tool(
               "edit_file",
               %{"path" => "replace.txt", "search" => "one", "replace" => "two"},
               workspace_root: workspace,
               permission_mode: :trusted
             )

    assert File.read!(path) == "two fish one fish"

    assert {:ok, %{replacements: 2}} =
             Core.run_tool(
               "edit_file",
               %{
                 "path" => "replace.txt",
                 "search" => "fish",
                 "replace" => "bird",
                 "occurrence" => "all",
                 "expected_replacements" => 2
               },
               workspace_root: workspace,
               permission_mode: :trusted
             )

    assert File.read!(path) == "two bird one bird"

    assert {:error, {:edit_file_failed, "replace.txt", {:replacement_count_mismatch, 2, 1}}} =
             Core.run_tool(
               "edit_file",
               %{
                 "path" => "replace.txt",
                 "search" => "one",
                 "replace" => "three",
                 "expected_replacements" => 2
               },
               workspace_root: workspace,
               permission_mode: :trusted
             )

    assert {:error, {:search_not_found, "replace.txt"}} =
             Core.run_tool(
               "edit_file",
               %{"path" => "replace.txt", "search" => "missing", "replace" => ""},
               workspace_root: workspace,
               permission_mode: :trusted
             )
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
