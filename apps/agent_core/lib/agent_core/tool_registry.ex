defmodule AgentCore.ToolRegistry do
  @moduledoc """
  Registry for built-in tool modules.

  The first implementation is a pure module so tests and future sessions can
  pass explicit tool lists without introducing another process.
  """

  @type tool_module :: module()

  @default_tools [
    AgentCore.Tools.ReadFile,
    AgentCore.Tools.ListFiles,
    AgentCore.Tools.Grep
  ]

  @doc """
  Returns the built-in tool modules.
  """
  @spec default_tools() :: [tool_module()]
  def default_tools, do: @default_tools

  @doc """
  Fetches a tool module by model-facing name.
  """
  @spec fetch(String.t(), [tool_module()]) ::
          {:ok, tool_module()} | {:error, {:unknown_tool, String.t()}}
  def fetch(name, tools \\ default_tools()) when is_binary(name) do
    case Enum.find(tools, &(normalize_name(&1.name()) == normalize_name(name))) do
      nil -> {:error, {:unknown_tool, name}}
      tool -> {:ok, tool}
    end
  end

  @doc """
  Returns schema maps for registered tools.
  """
  @spec schemas([tool_module()]) :: [map()]
  def schemas(tools \\ default_tools()) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name(),
        description: tool.description(),
        schema: tool.schema(),
        safety: tool.safety()
      }
    end)
  end

  defp normalize_name(name) do
    String.downcase(name)
  end
end
