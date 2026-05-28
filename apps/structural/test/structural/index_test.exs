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

  test "fetch returns :not_found for unknown ids", %{workspace: workspace, index: index} do
    {:ok, _status} = Index.index_path(index, workspace)
    assert {:error, :not_found} = Index.fetch(index, "lib/calc.ex:module:Nope@0")
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
