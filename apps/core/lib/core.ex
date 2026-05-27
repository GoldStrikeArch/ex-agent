defmodule Core do
  @moduledoc """
  Public facade for the agent runtime OTP application.

  The core app owns sessions, event publication, model client contracts, and
  tool execution infrastructure. UI applications should talk to this module or
  subscribe to `Core.EventBus` instead of reaching into session internals.
  """

  @doc """
  Starts a supervised agent session.
  """
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts \\ []) do
    Core.SessionSupervisor.start_session(opts)
  end

  @doc """
  Stops a supervised agent session.
  """
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(pid) when is_pid(pid) do
    Core.SessionSupervisor.stop_session(pid)
  end

  @doc """
  Sends a user message to a session.
  """
  @spec send_message(pid(), String.t()) ::
          {:ok, %{message_id: String.t(), content: String.t()}} | {:error, term()}
  def send_message(pid, text) when is_pid(pid) and is_binary(text) do
    Core.AgentSession.send_message(pid, text)
  end

  @doc """
  Returns a session transcript in chronological order.
  """
  @spec messages(pid()) :: {:ok, [Core.AgentSession.message()]}
  def messages(pid) when is_pid(pid) do
    Core.AgentSession.messages(pid)
  end

  @doc """
  Cancels the active turn of a session, keeping the session alive.
  """
  @spec abort(pid()) :: :ok | {:error, :no_active_turn}
  def abort(pid) when is_pid(pid) do
    Core.AgentSession.abort(pid)
  end

  @doc """
  Reconfigures a live session model client for subsequent turns.
  """
  @spec configure_model(pid(), keyword()) :: :ok | {:error, term()}
  def configure_model(pid, opts) when is_pid(pid) and is_list(opts) do
    Core.AgentSession.configure_model(pid, opts)
  end

  @doc """
  Runs a registered tool through the deterministic executor.
  """
  @spec run_tool(String.t() | atom(), map(), keyword()) ::
          {:ok, Core.Tool.result()} | {:error, term()}
  def run_tool(name, args, opts \\ []) do
    Core.ToolExecutor.run(name, args, opts)
  end
end
