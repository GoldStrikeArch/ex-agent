defmodule AgentCore do
  @moduledoc """
  Public facade for the agent runtime OTP application.

  The core app owns sessions, event publication, model client contracts, and
  tool execution infrastructure. UI applications should talk to this module or
  subscribe to `AgentCore.EventBus` instead of reaching into session internals.
  """

  @doc """
  Starts a supervised agent session.
  """
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts \\ []) do
    AgentCore.SessionSupervisor.start_session(opts)
  end

  @doc """
  Stops a supervised agent session.
  """
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(pid) when is_pid(pid) do
    AgentCore.SessionSupervisor.stop_session(pid)
  end

  @doc """
  Sends a user message to a session.
  """
  @spec send_message(pid(), String.t()) ::
          {:ok, %{message_id: String.t(), content: String.t()}} | {:error, term()}
  def send_message(pid, text) when is_pid(pid) and is_binary(text) do
    AgentCore.AgentSession.send_message(pid, text)
  end

  @doc """
  Returns a session transcript in chronological order.
  """
  @spec messages(pid()) :: {:ok, [AgentCore.AgentSession.message()]}
  def messages(pid) when is_pid(pid) do
    AgentCore.AgentSession.messages(pid)
  end

  @doc """
  Runs a registered tool through the deterministic executor.
  """
  @spec run_tool(String.t() | atom(), map(), keyword()) ::
          {:ok, AgentCore.Tool.result()} | {:error, term()}
  def run_tool(name, args, opts \\ []) do
    AgentCore.ToolExecutor.run(name, args, opts)
  end
end
