defmodule AgentApp.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias AgentApp.ModelCatalog

  test "default instructions guide structural-tool use with grep/read_file fallback" do
    instructions = ModelCatalog.default().instructions

    assert instructions =~ "symbol_search"
    assert instructions =~ "ast_outline"
    assert instructions =~ "fetch_node"
    assert instructions =~ "fall back to grep and read_file"
    assert instructions =~ "batch"
  end
end
