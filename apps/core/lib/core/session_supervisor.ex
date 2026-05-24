defmodule Core.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for agent sessions.
  """

  use DynamicSupervisor

  @doc """
  Starts the dynamic session supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @doc """
  Starts a supervised session.
  """
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {Core.AgentSession, opts})
  end

  @doc """
  Stops a supervised session.
  """
  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  def stop_session(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
