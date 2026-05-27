defmodule Core.Tools.BatchTest do
  use ExUnit.Case, async: false

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "agent-batch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "a.txt"), "alpha")
    File.write!(Path.join(workspace, "b.txt"), "beta")
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  defp run_batch(calls, opts) do
    Core.run_tool("batch", %{"calls" => calls}, opts)
  end

  defp index_of(haystack, needle), do: :binary.match(haystack, needle) |> elem(0)

  test "runs nested read tools through the scheduler in order", %{workspace: workspace} do
    calls = [
      %{"id" => "c1", "tool" => "read_file", "args" => %{"path" => "a.txt"}},
      %{"id" => "c2", "tool" => "read_file", "args" => %{"path" => "b.txt"}}
    ]

    assert {:ok, %{status: :ok, output: output}} =
             run_batch(calls, workspace_root: workspace, permission_mode: :read_only)

    assert output =~ ~s("id":"c1")
    assert output =~ ~s("id":"c2")
    assert output =~ "alpha"
    assert output =~ "beta"
    # Children are emitted in source order.
    assert index_of(output, "c1") < index_of(output, "c2")
  end

  test "nested permission failures come back as child results", %{workspace: workspace} do
    calls = [
      %{"id" => "ok", "tool" => "read_file", "args" => %{"path" => "a.txt"}},
      %{
        "id" => "denied",
        "tool" => "write_file",
        "args" => %{"path" => "x.txt", "content" => "no"}
      }
    ]

    # read_only mode: the batch tool itself is allowed, the nested write is denied.
    assert {:ok, %{status: :error, output: output}} =
             run_batch(calls, workspace_root: workspace, permission_mode: :read_only)

    assert output =~ "permission_denied"
    assert output =~ ~s("status":"error")
    refute File.exists?(Path.join(workspace, "x.txt"))
  end

  test "nested batch calls are rejected as child errors", %{workspace: workspace} do
    calls = [
      %{"id" => "outer", "tool" => "batch", "args" => %{"calls" => []}},
      %{"id" => "read", "tool" => "read_file", "args" => %{"path" => "a.txt"}}
    ]

    assert {:ok, %{status: :error, output: output}} =
             run_batch(calls, workspace_root: workspace, permission_mode: :read_only)

    assert output =~ "nested_batch_not_supported"
    assert output =~ "alpha"
  end

  test "rejects malformed calls with a tagged error", %{workspace: workspace} do
    assert {:error, {:invalid_argument, :calls, nil}} =
             Core.run_tool("batch", %{}, workspace_root: workspace, permission_mode: :read_only)

    assert {:error, {:invalid_batch_call, :tool, _}} =
             run_batch([%{"args" => %{}}], workspace_root: workspace, permission_mode: :read_only)
  end
end
