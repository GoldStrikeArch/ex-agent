defmodule Structural.IndexTest do
  use ExUnit.Case, async: false

  alias Structural.Index

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "structural-index-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.mkdir_p!(Path.join(workspace, "_build"))

    File.write!(Path.join(workspace, "lib/calc.ex"), """
    defmodule Calc do
      def add(a, b), do: a + b
      defp helper, do: :ok
    end
    """)

    File.write!(Path.join(workspace, "lib/app.py"), """
    class App:
        def run(self):
            return 1
    """)

    # Should be ignored by the walker.
    File.write!(Path.join(workspace, "_build/ignored.ex"), "defmodule Ignored do\nend\n")

    # Linked to the test process, so it terminates with the test (no manual stop).
    {:ok, index} = Index.start_link(name: nil, path: ":memory:")

    %{workspace: workspace, index: index}
  end

  test "indexes supported files and reports coverage", %{workspace: workspace, index: index} do
    assert {:ok, status} = Index.index_path(index, workspace)
    assert status.files == 2
    assert status.symbols >= 4
    assert "elixir" in status.languages
    assert "python" in status.languages
    assert status.indexed
  end

  test "ignores _build and other vendored directories", %{workspace: workspace, index: index} do
    {:ok, _status} = Index.index_path(index, workspace)
    assert {:ok, []} = Index.outline(index, "_build/ignored.ex")
  end

  test "files lists indexed files under a path", %{workspace: workspace, index: index} do
    {:ok, _status} = Index.index_path(index, workspace)

    assert {:ok, files} = Index.files(index, path: "lib")
    assert Enum.map(files, & &1.path) == ["lib/app.py", "lib/calc.ex"]
    assert Enum.all?(files, &(&1.symbol_count > 0))

    assert {:ok, []} = Index.files(index, path: "missing")
  end

  test "outlines returns recursive file and symbol maps", %{workspace: workspace, index: index} do
    {:ok, _status} = Index.index_path(index, workspace)

    assert {:ok, outlines} = Index.outlines(index, path: "lib", symbol_limit_per_file: 2)
    calc = Enum.find(outlines, &(&1.path == "lib/calc.ex"))
    assert Enum.map(calc.symbols, & &1.name) == ["Calc", "add/2"]
  end

  test "outline returns a file's symbols in source order", %{workspace: workspace, index: index} do
    {:ok, _status} = Index.index_path(index, workspace)
    assert {:ok, symbols} = Index.outline(index, "lib/calc.ex")

    assert Enum.map(symbols, & &1.name) == ["Calc", "add/2", "helper/0"]
    [module, add, helper] = symbols
    assert module.kind == "module"
    assert add.kind == "function"
    assert add.parent_id == module.id
    assert helper.kind == "private_function"
  end

  test "search finds symbols by exact and arity-qualified name", %{
    workspace: workspace,
    index: index
  } do
    {:ok, _status} = Index.index_path(index, workspace)

    assert {:ok, [calc]} = Index.search(index, "Calc")
    assert calc.name == "Calc"
    assert calc.path == "lib/calc.ex"

    # "add" matches the arity-qualified "add/2".
    assert {:ok, [add]} = Index.search(index, "add")
    assert add.name == "add/2"

    assert {:ok, results} = Index.search(index, "add", kind: :private_function)
    assert results == []
  end

  test "symbols supports path and kind filters", %{workspace: workspace, index: index} do
    {:ok, _status} = Index.index_path(index, workspace)

    assert {:ok, modules} = Index.symbols(index, path: "lib", kind: "module")
    assert Enum.map(modules, & &1.name) == ["Calc"]

    assert {:ok, functions} = Index.symbols(index, path: "lib/calc.ex", kinds: ["function"])
    assert Enum.map(functions, & &1.name) == ["add/2"]
  end

  test "fetch returns the exact current source slice and verifies the hash", %{
    workspace: workspace,
    index: index
  } do
    {:ok, _status} = Index.index_path(index, workspace)
    {:ok, [add]} = Index.search(index, "add")

    assert {:ok, node} = Index.fetch(index, add.id)
    assert node.content =~ "def add(a, b)"
    assert is_binary(node.file_hash)

    # Mutating the file on disk makes the indexed byte range stale.
    File.write!(Path.join(workspace, "lib/calc.ex"), "defmodule Calc do\nend\n")
    assert {:error, :stale} = Index.fetch(index, add.id)
  end

  test "fetch_file returns a whole indexed file and verifies the hash", %{
    workspace: workspace,
    index: index
  } do
    {:ok, _status} = Index.index_path(index, workspace)

    assert {:ok, file} = Index.fetch_file(index, "lib/calc.ex")
    assert file.path == "lib/calc.ex"
    assert file.content =~ "defmodule Calc"
    assert file.content =~ "defp helper"

    File.write!(Path.join(workspace, "lib/calc.ex"), "defmodule Calc do\nend\n")
    assert {:error, :stale} = Index.fetch_file(index, "lib/calc.ex")
  end

  test "fetch returns :not_found for unknown ids", %{workspace: workspace, index: index} do
    {:ok, _status} = Index.index_path(index, workspace)
    assert {:error, :not_found} = Index.fetch(index, "lib/calc.ex:module:Nope@0")
    assert {:error, :not_found} = Index.fetch_file(index, "lib/missing.ex")
  end

  test "re-indexing updates changed files and prunes deleted ones", %{
    workspace: workspace,
    index: index
  } do
    {:ok, _status} = Index.index_path(index, workspace)

    # Change calc.ex (add a function) and delete app.py.
    File.write!(Path.join(workspace, "lib/calc.ex"), """
    defmodule Calc do
      def add(a, b), do: a + b
      def sub(a, b), do: a - b
    end
    """)

    File.rm!(Path.join(workspace, "lib/app.py"))

    assert {:ok, status} = Index.index_path(index, workspace)
    assert status.files == 1
    assert "python" not in status.languages

    assert {:ok, symbols} = Index.outline(index, "lib/calc.ex")
    assert "sub/2" in Enum.map(symbols, & &1.name)
    refute "helper/0" in Enum.map(symbols, & &1.name)
  end
end
