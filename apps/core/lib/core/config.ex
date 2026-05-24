defmodule Core.Config do
  @moduledoc """
  Loads runtime configuration for the agent core.

  Values can come from the `:core` application environment or explicit
  keyword options. Explicit options win over application environment values.
  """

  @type permission_mode :: :read_only | :workspace_write | :ask_before_shell | :trusted

  @type t :: %__MODULE__{
          agent_dir: Path.t(),
          auth_provider: atom() | nil,
          base_url: String.t() | nil,
          model_provider: atom(),
          model: String.t(),
          provider: atom(),
          reasoning_effort: String.t() | nil,
          timeout_ms: pos_integer(),
          workspace_root: Path.t(),
          permission_mode: permission_mode()
        }

  defstruct agent_dir: nil,
            auth_provider: nil,
            base_url: nil,
            model_provider: :mock,
            model: "mock",
            provider: :mock,
            reasoning_effort: nil,
            timeout_ms: 120_000,
            workspace_root: nil,
            permission_mode: :read_only

  @doc """
  Builds a config struct.

  Returns `{:error, {:invalid_permission_mode, value}}` for unknown permission
  modes.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, {:invalid_permission_mode, term()}}
  def load(opts \\ []) do
    values = Keyword.merge(Application.get_all_env(:core), opts)

    with {:ok, permission_mode} <-
           parse_permission_mode(Keyword.get(values, :permission_mode, :read_only)) do
      {:ok,
       %__MODULE__{
         agent_dir: Keyword.get_lazy(values, :agent_dir, &default_agent_dir/0),
         auth_provider: Keyword.get(values, :auth_provider),
         base_url: Keyword.get(values, :base_url),
         model_provider: Keyword.get(values, :model_provider, :mock),
         model: Keyword.get(values, :model, "mock"),
         provider: Keyword.get(values, :provider, Keyword.get(values, :model_provider, :mock)),
         reasoning_effort: Keyword.get(values, :reasoning_effort),
         timeout_ms: Keyword.get(values, :timeout_ms, 120_000),
         workspace_root: Keyword.get_lazy(values, :workspace_root, &File.cwd!/0),
         permission_mode: permission_mode
       }}
    end
  end

  defp default_agent_dir do
    System.get_env("ELIXIR_AGENT_DIR") ||
      Path.join([System.user_home!(), ".elixir-agent", "agent"])
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
