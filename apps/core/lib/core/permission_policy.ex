defmodule Core.PermissionPolicy do
  @moduledoc """
  Evaluates whether a tool is allowed to run in the current permission mode.

  The policy is deliberately non-interactive for this slice. Denials are
  returned as structured values so the tool executor can emit normal failure
  events and feed the result back to the model loop.
  """

  @type mode :: :read_only | :workspace_write | :ask_before_shell | :trusted
  @type decision :: :ok | {:error, {:permission_denied, mode(), String.t(), Core.Tool.safety()}}

  @doc """
  Returns `:ok` when `tool_name` with `safety` may run in `mode`.
  """
  @spec authorize(mode(), String.t(), Core.Tool.safety()) :: decision()
  def authorize(:trusted, _tool_name, safety)
      when safety in [:read_only, :write, :shell, :risky] do
    :ok
  end

  def authorize(:read_only, _tool_name, :read_only), do: :ok
  def authorize(:workspace_write, _tool_name, safety) when safety in [:read_only, :write], do: :ok

  def authorize(:ask_before_shell, _tool_name, safety) when safety in [:read_only, :write],
    do: :ok

  def authorize(mode, tool_name, safety)
      when mode in [:read_only, :workspace_write, :ask_before_shell, :trusted] and
             safety in [:read_only, :write, :shell, :risky] and is_binary(tool_name) do
    {:error, {:permission_denied, mode, tool_name, safety}}
  end

  def authorize(mode, tool_name, safety) when is_binary(tool_name) do
    {:error, {:permission_denied, mode, tool_name, safety}}
  end
end
