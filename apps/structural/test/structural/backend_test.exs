defmodule Structural.BackendTest do
  use ExUnit.Case, async: false

  alias Structural.Backend
  alias Structural.Index

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "structural-backend-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "lib"))

    File.write!(Path.join(workspace, "lib/calc.ex"), """
    defmodule Calc do
      def add(a, b), do: a + b

      def double(n) do
        Calc.add(n, n)
      end
    end
    """)

    on_exit(fn -> File.rm_rf(workspace) end)

    # Linked to the test process, so it terminates with the test (no manual stop).
    {:ok, index} = Index.start_link(name: nil, path: ":memory:")
    {:ok, _status} = Index.index_path(index, workspace)

    %{
      workspace: workspace,
      index: index,
      context: %{workspace_root: workspace, structural_index: index}
    }
  end

  test "implements the Core structural backend behaviour and is available" do
    behaviours = Backend.module_info(:attributes) |> Keyword.get_values(:behaviour)
    assert Core.Structural.Backend in List.flatten(behaviours)
    assert Backend.available?()
  end

  test "the structural application supervises a registered index" do
    assert is_pid(Process.whereis(Index))
  end

  test "returns :unavailable when no index process is running" do
    assert Backend.run(:symbol_search, %{query: "Calc"}, %{structural_index: :missing_index}) ==
             :unavailable
  end

  test "index_status reports coverage", %{context: context} do
    assert {:ok, result} = Backend.run(:index_status, %{}, context)
    assert result.status == :ok
    assert result.files == 1
    assert result.symbols >= 2
    assert "elixir" in result.languages
  end

  test "index_repo re-indexes the workspace", %{context: context} do
    assert {:ok, result} = Backend.run(:index_repo, %{path: "."}, context)
    assert result.status == :ok
    assert result.files == 1
    assert result.summary =~ "indexed 1 files"
  end

  test "ast_outline lists a file's symbols", %{context: context} do
    assert {:ok, result} = Backend.run(:ast_outline, %{path: "lib/calc.ex"}, context)
    assert result.status == :ok
    assert Enum.map(result.symbols, & &1.name) == ["Calc", "add/2", "double/1"]
    assert result.output =~ "function add/2"
  end

  test "ast_outline on an unindexed file reports not_indexed", %{context: context} do
    assert {:ok, result} = Backend.run(:ast_outline, %{path: "lib/missing.ex"}, context)
    assert result.status == :not_indexed
    assert result.symbols == []
  end

  test "symbol_search finds definitions by name", %{context: context} do
    assert {:ok, result} = Backend.run(:symbol_search, %{query: "add"}, context)
    assert result.status == :ok
    assert [%{name: "add/2", path: "lib/calc.ex"}] = result.matches
    assert result.output =~ "lib/calc.ex:2 function add/2"
  end

  test "definitions resolves module-qualified names", %{context: context} do
    assert {:ok, result} = Backend.run(:definitions, %{symbol: "Calc.add"}, context)
    assert "add/2" in Enum.map(result.matches, & &1.name)
  end

  test "callers finds call sites of a function", %{context: context} do
    assert {:ok, result} = Backend.run(:callers, %{symbol: "add"}, context)
    assert [caller] = result.callers
    assert caller.path == "lib/calc.ex"
    assert caller.caller == "double/1"
    assert result.output =~ "(in double/1)"
  end

  test "fetch_node returns the exact source slice", %{context: context, index: index} do
    {:ok, [add]} = Index.search(index, "add")

    assert {:ok, result} =
             Backend.run(:fetch_node, %{symbol_id: add.id, include_comments: true}, context)

    assert result.status == :ok
    assert result.content =~ "def add(a, b)"
  end

  test "fetch_node reports stale nodes instead of erroring", %{
    context: context,
    index: index,
    workspace: workspace
  } do
    {:ok, [add]} = Index.search(index, "add")
    File.write!(Path.join(workspace, "lib/calc.ex"), "defmodule Calc do\nend\n")

    assert {:ok, result} = Backend.run(:fetch_node, %{symbol_id: add.id}, context)
    assert result.status == :stale
    assert result.output =~ "stale"
  end

  test "ast_query is not supported yet", %{context: context} do
    assert {:error, :unsupported_query} = Backend.run(:ast_query, %{query: "(x)"}, context)
  end

  test "drives the core structural tools end-to-end with real data", %{workspace: workspace} do
    # The structural app supervises a registered index; start one only if needed.
    unless Process.whereis(Index), do: start_supervised!({Index, name: Index, path: ":memory:"})

    opts = [
      workspace_root: workspace,
      permission_mode: :read_only,
      structural_backend: Backend
    ]

    assert {:ok, %{status: :ok}} = Core.run_tool("index_repo", %{"path" => "."}, opts)

    assert {:ok, %{status: :ok, output: output}} =
             Core.run_tool("symbol_search", %{"query" => "Calc"}, opts)

    assert output =~ "lib/calc.ex"

    assert {:ok, %{status: :ok}} = Core.run_tool("ast_outline", %{"path" => "lib/calc.ex"}, opts)
  end
end
