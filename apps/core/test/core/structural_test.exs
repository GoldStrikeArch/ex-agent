defmodule Core.StructuralTest do
  use ExUnit.Case, async: false

  @structural_tools [
    Core.Tools.Structural.IndexRepo,
    Core.Tools.Structural.IndexStatus,
    Core.Tools.Structural.IndexedFiles,
    Core.Tools.Structural.IndexedOutline,
    Core.Tools.Structural.AstOutline,
    Core.Tools.Structural.SymbolSearch,
    Core.Tools.Structural.AstQuery,
    Core.Tools.Structural.ReadIndexedFile,
    Core.Tools.Structural.FetchNode,
    Core.Tools.Structural.Definitions,
    Core.Tools.Structural.Callers
  ]

  @stub_calls [
    {"index_repo", %{}},
    {"index_status", %{}},
    {"indexed_files", %{"path" => "lib"}},
    {"indexed_outline", %{"path" => "lib"}},
    {"ast_outline", %{"path" => "lib/foo.ex"}},
    {"symbol_search", %{"query" => "Foo"}},
    {"ast_query", %{"query" => "defmodule", "path" => "lib"}},
    {"read_indexed_file", %{"path" => "lib/foo.ex"}},
    {"fetch_node", %{"symbol_id" => "sym-1"}},
    {"definitions", %{"symbol" => "Foo.bar"}},
    {"callers", %{"symbol" => "Foo.bar"}}
  ]

  test "structural tools are available and are the agent defaults" do
    defaults = Core.ToolRegistry.default_tools()
    agent_defaults = Core.ToolRegistry.agent_default_tools()

    assert Enum.all?(@structural_tools, &(&1 in defaults))
    assert agent_defaults == @structural_tools

    names = agent_defaults |> Core.ToolRegistry.schemas() |> Enum.map(& &1.name)

    for tool <- @structural_tools do
      assert tool.name() in names
      assert tool.safety() == :read_only
    end
  end

  test "each stub returns a backend_unavailable result with stable keys" do
    for {name, args} <- @stub_calls do
      assert {:ok, result} = Core.run_tool(name, args, permission_mode: :read_only)

      assert result.status == :backend_unavailable
      assert result.operation == name
      assert result.available == false
      assert is_binary(result.summary)
      assert result.output =~ "structural backend unavailable"
    end
  end

  test "unavailable stubs are successful results, not tool errors" do
    assert {:ok, %{status: :backend_unavailable}} =
             Core.run_tool("symbol_search", %{"query" => "X"}, permission_mode: :read_only)
  end

  test "invalid structural arguments return tagged errors" do
    assert {:error, {:invalid_argument, :path, _}} =
             Core.run_tool("ast_outline", %{}, permission_mode: :read_only)

    assert {:error, {:invalid_argument, :query, _}} =
             Core.run_tool("symbol_search", %{}, permission_mode: :read_only)

    assert {:error, {:invalid_argument, :symbol, _}} =
             Core.run_tool("definitions", %{}, permission_mode: :read_only)

    assert {:error, {:invalid_argument, :path, _}} =
             Core.run_tool("read_indexed_file", %{}, permission_mode: :read_only)
  end

  test "a configured backend is used over the default unavailable one" do
    defmodule StubBackend do
      @behaviour Core.Structural.Backend
      @impl true
      def available?, do: true
      @impl true
      def run(:symbol_search, %{query: query}, _context) do
        {:ok, %{status: :ok, matches: [query], output: "found #{query}"}}
      end
    end

    assert {:ok, %{status: :ok, matches: ["Foo"]}} =
             Core.run_tool("symbol_search", %{"query" => "Foo"},
               permission_mode: :read_only,
               structural_backend: StubBackend
             )
  end
end
