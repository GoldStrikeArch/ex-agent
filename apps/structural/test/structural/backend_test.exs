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

  test "indexed_files lists indexed files", %{context: context} do
    assert {:ok, result} = Backend.run(:indexed_files, %{path: "lib"}, context)
    assert result.status == :ok
    assert [%{path: "lib/calc.ex", language: "elixir"}] = result.files
    assert result.output =~ "lib/calc.ex elixir"
  end

  test "indexed_outline lists files with path-scoped symbols", %{context: context} do
    assert {:ok, result} =
             Backend.run(
               :indexed_outline,
               %{path: "lib", limit: 10, symbol_limit_per_file: 10},
               context
             )

    assert result.status == :ok
    assert [%{path: "lib/calc.ex", symbols: symbols}] = result.files
    assert Enum.map(symbols, & &1.name) == ["Calc", "add/2", "double/1"]
    assert result.output =~ "lib/calc.ex elixir"
    assert result.output =~ "id=lib/calc.ex:function:add/2@"
  end

  test "ast_outline lists a file's symbols", %{context: context} do
    assert {:ok, result} = Backend.run(:ast_outline, %{path: "lib/calc.ex"}, context)
    assert result.status == :ok
    assert Enum.map(result.symbols, & &1.name) == ["Calc", "add/2", "double/1"]
    assert result.output =~ "function add/2"
    assert result.output =~ "id=lib/calc.ex:function:add/2@"
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
    assert result.output =~ "id=lib/calc.ex:function:add/2@"
  end

  test "symbol_search respects path scope", %{context: context} do
    assert {:ok, %{matches: [%{name: "add/2"}]}} =
             Backend.run(:symbol_search, %{query: "add", path: "lib"}, context)

    assert {:ok, %{matches: [], output: ""}} =
             Backend.run(:symbol_search, %{query: "add", path: "missing"}, context)
  end

  test "definitions resolves module-qualified names", %{context: context} do
    assert {:ok, result} = Backend.run(:definitions, %{symbol: "Calc.add"}, context)
    assert "add/2" in Enum.map(result.matches, & &1.name)
  end

  test "definitions respects path scope", %{context: context} do
    assert {:ok, %{matches: []}} =
             Backend.run(:definitions, %{symbol: "Calc.add", path: "missing"}, context)
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

  test "read_indexed_file returns full indexed file contents", %{context: context} do
    assert {:ok, result} =
             Backend.run(:read_indexed_file, %{path: "lib/calc.ex", max_bytes: 1_000}, context)

    assert result.status == :ok
    assert result.path == "lib/calc.ex"
    assert result.content =~ "defmodule Calc"
    assert result.content =~ "def double"
    refute result.truncated
  end

  test "read_indexed_file reports stale files instead of erroring", %{
    context: context,
    workspace: workspace
  } do
    File.write!(Path.join(workspace, "lib/calc.ex"), "defmodule Calc do\nend\n")

    assert {:ok, result} = Backend.run(:read_indexed_file, %{path: "lib/calc.ex"}, context)
    assert result.status == :stale
    assert result.output =~ "stale"
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

  test "ast_query returns index-backed structural matches", %{context: context} do
    assert {:ok, modules} = Backend.run(:ast_query, %{query: "defmodule", path: "lib"}, context)
    assert modules.status == :ok
    assert modules.query_kind == :symbols
    assert [%{name: "Calc", kind: "module"}] = modules.matches

    assert {:ok, files} = Backend.run(:ast_query, %{query: "source_file", path: "lib"}, context)
    assert [%{path: "lib/calc.ex"}] = files.matches

    assert {:ok, calls} = Backend.run(:ast_query, %{query: "call name:add", path: "lib"}, context)
    assert [%{callee: "add", caller: "double/1"}] = calls.matches
  end

  test "ast_query reports unsupported patterns as tool results", %{context: context} do
    assert {:ok, result} = Backend.run(:ast_query, %{query: "(x)"}, context)
    assert result.status == :unsupported_query
    assert result.output =~ "unsupported structural query"
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
             Core.run_tool("symbol_search", %{"query" => "Calc", "path" => "lib"}, opts)

    assert output =~ "lib/calc.ex"
    assert output =~ "id="

    assert {:ok, %{status: :ok}} = Core.run_tool("ast_outline", %{"path" => "lib/calc.ex"}, opts)

    assert {:ok, %{status: :ok, files: [%{path: "lib/calc.ex"}]}} =
             Core.run_tool("indexed_files", %{"path" => "lib"}, opts)

    assert {:ok, %{status: :ok, files: [%{path: "lib/calc.ex"}]}} =
             Core.run_tool("indexed_outline", %{"path" => "lib"}, opts)

    assert {:ok, %{status: :ok, content: content}} =
             Core.run_tool("read_indexed_file", %{"path" => "lib/calc.ex"}, opts)

    assert content =~ "defmodule Calc"

    assert {:ok, %{status: :ok, matches: [%{name: "Calc"}]}} =
             Core.run_tool("ast_query", %{"query" => "defmodule", "path" => "lib"}, opts)
  end
end
