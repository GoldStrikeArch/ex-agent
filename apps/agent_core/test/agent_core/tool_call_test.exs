defmodule AgentCore.ToolCallTest do
  use ExUnit.Case, async: true

  test "normalizes atom and string keyed tool calls" do
    assert {:ok, %{id: "tool-1", name: "read_file", args: %{path: "mix.exs"}}} =
             AgentCore.ToolCall.normalize(%{
               id: "tool-1",
               name: "read_file",
               args: %{path: "mix.exs"}
             })

    assert {:ok,
            %{
              id: "tool-2",
              provider_id: "fc_2",
              name: "grep",
              args: %{"pattern" => "defmodule"}
            }} =
             AgentCore.ToolCall.normalize(%{
               "id" => "tool-2",
               "provider_id" => "fc_2",
               "name" => "grep",
               "args" => %{"pattern" => "defmodule"}
             })
  end

  test "fills missing IDs and rejects invalid calls" do
    assert {:ok, %{id: "tool-" <> _suffix, name: "list_files", args: %{}}} =
             AgentCore.ToolCall.normalize(%{name: "list_files", args: %{}})

    assert {:error, {:invalid_tool_call, %{id: "", name: "read_file", args: %{}}}} =
             AgentCore.ToolCall.normalize(%{id: "", name: "read_file", args: %{}})
  end
end
