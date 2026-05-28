defmodule AgentApp.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias AgentApp.ModelCatalog

  test "default instructions push structural-only tool use" do
    instructions = ModelCatalog.default().instructions

    # Parallel-tool guidance for structural lookups.
    assert instructions =~ "Parallelize"
    assert instructions =~ "sibling tool calls in the same assistant response"
    assert instructions =~ "Do not request structural lookups one at a time"

    # Structural-only guidance.
    assert instructions =~ "index_status"
    assert instructions =~ "index_repo"
    assert instructions =~ "indexed_files"
    assert instructions =~ "indexed_outline"
    assert instructions =~ "read_indexed_file"
    assert instructions =~ "symbol_search"
    assert instructions =~ "ast_outline"
    assert instructions =~ "ast_query"
    assert instructions =~ "fetch_node"
    assert instructions =~ "Prefer one indexed_outline call over many ast_outline calls"
    assert instructions =~ "Do not invent symbol ids"
    assert instructions =~ "shell, grep, list_files, read_file, edit_file, write_file, or batch"
  end

  test "catalog model options include a configurable thinking level" do
    option = ModelCatalog.default()

    assert option.thinking_level == "medium"
    assert "high" in option.thinking_levels
    assert {:ok, high} = ModelCatalog.with_thinking_level(option, "high")
    assert high.thinking_level == "high"
    assert ModelCatalog.core_opts(high)[:model_opts][:reasoning_effort] == "high"
  end
end
