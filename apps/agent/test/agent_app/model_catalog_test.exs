defmodule AgentApp.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias AgentApp.ModelCatalog

  test "default instructions push parallel tool calls and structural-tool use" do
    instructions = ModelCatalog.default().instructions

    # Parallel-tool guidance — the highest-impact nudge for end-to-end latency.
    assert instructions =~ "Parallelize"
    assert instructions =~ "sibling tool calls in the same assistant response"
    assert instructions =~ "`batch` tool"
    assert instructions =~ "Do not request files one at a time"

    # Structural-tool guidance.
    assert instructions =~ "symbol_search"
    assert instructions =~ "ast_outline"
    assert instructions =~ "fetch_node"
    assert instructions =~ "fall back to grep and read_file"
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
