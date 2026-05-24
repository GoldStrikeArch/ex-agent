defmodule AgentCore.Config do
  @moduledoc """
  Loads runtime configuration for the agent core.

  Values can come from the `:agent_core` application environment or explicit
  keyword options. Explicit options win over application environment values.
  """

  @type permission_mode :: :read_only | :workspace_write | :ask_before_shell | :trusted

  @type t :: %__MODULE__{
          model_provider: atom(),
          model: String.t(),
          workspace_root: Path.t(),
          permission_mode: permission_mode()
        }

  defstruct model_provider: :mock,
            model: "mock",
            workspace_root: nil,
            permission_mode: :read_only

  @doc """
  Builds a config struct.

  Returns `{:error, {:invalid_permission_mode, value}}` for unknown permission
  modes.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, {:invalid_permission_mode, term()}}
  def load(opts \\ []) do
    values = Keyword.merge(Application.get_all_env(:agent_core), opts)

    with {:ok, permission_mode} <-
           parse_permission_mode(Keyword.get(values, :permission_mode, :read_only)) do
      {:ok,
       %__MODULE__{
         model_provider: Keyword.get(values, :model_provider, :mock),
         model: Keyword.get(values, :model, "mock"),
         workspace_root: Keyword.get_lazy(values, :workspace_root, &File.cwd!/0),
         permission_mode: permission_mode
       }}
    end
  end

  defp parse_permission_mode(mode)
       when mode in [:read_only, :workspace_write, :ask_before_shell, :trusted] do
    {:ok, mode}
  end

  defp parse_permission_mode("read-only"), do: {:ok, :read_only}
  defp parse_permission_mode("read_only"), do: {:ok, :read_only}
  defp parse_permission_mode("workspace-write"), do: {:ok, :workspace_write}
  defp parse_permission_mode("workspace_write"), do: {:ok, :workspace_write}
  defp parse_permission_mode("ask-before-shell"), do: {:ok, :ask_before_shell}
  defp parse_permission_mode("ask_before_shell"), do: {:ok, :ask_before_shell}
  defp parse_permission_mode("trusted"), do: {:ok, :trusted}
  defp parse_permission_mode(mode), do: {:error, {:invalid_permission_mode, mode}}
end
