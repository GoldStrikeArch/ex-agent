defmodule AgentTui.TerminalApp do
  @moduledoc """
  Starts the full-screen terminal UI and owns the agent session lifecycle.
  """

  alias AgentTui.TerminalApp.Root
  alias AgentTui.TerminalApp.EventBridge

  @doc """
  Runs the terminal UI until the user exits.

  Options:

    * `:session_opts` - options passed to `AgentCore.start_session/1`.
    * `:initial_prompt` - optional text placed into the first turn.
    * `:backend` - TermUI backend selection, defaults to `:auto`.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started(:agent_tui)

    {session_opts, runtime_opts} = Keyword.pop(opts, :session_opts, [])

    runtime_opts =
      runtime_opts
      |> Keyword.put(:root, Root)
      |> Keyword.put(:subscribe, false)
      |> Keyword.put_new(:backend, :auto)
      |> Keyword.put_new(:task_supervisor, AgentTui.TaskSupervisor)

    run_runtime(runtime_opts, session_opts)
  end

  @doc """
  Starts a TermUI runtime for tests or supervised embedding.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts
    |> Keyword.put(:root, Root)
    |> Keyword.put_new(:subscribe, false)
    |> TermUI.Runtime.start_link()
  end

  defp run_runtime(opts, session_opts) do
    initial_prompt = Keyword.get(opts, :initial_prompt, "")

    case TermUI.Runtime.start_link(opts) do
      {:ok, runtime} ->
        {:ok, bridge} = EventBridge.start_link(runtime: runtime)
        start_session_and_wait(runtime, bridge, session_opts, initial_prompt)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_session_and_wait(runtime, bridge, session_opts, initial_prompt) do
    case AgentCore.start_session(session_opts) do
      {:ok, session} ->
        try do
          TermUI.Runtime.send_message(runtime, :root, {:set_session, session})
          maybe_submit_initial_prompt(runtime, initial_prompt)
          wait_for_runtime(runtime, bridge)
        after
          AgentCore.stop_session(session)
        end

      {:error, reason} ->
        TermUI.Runtime.shutdown(runtime)
        stop_bridge(bridge)
        {:error, reason}
    end
  end

  defp maybe_submit_initial_prompt(_runtime, ""), do: :ok
  defp maybe_submit_initial_prompt(_runtime, nil), do: :ok

  defp maybe_submit_initial_prompt(runtime, prompt) when is_binary(prompt) do
    TermUI.Runtime.send_message(runtime, :root, {:submit_initial, prompt})
  end

  defp wait_for_runtime(runtime, bridge) do
    ref = Process.monitor(runtime)

    receive do
      {:DOWN, ^ref, :process, ^runtime, _reason} ->
        stop_bridge(bridge)
        :ok
    end
  end

  defp stop_bridge(bridge) do
    if Process.alive?(bridge) do
      GenServer.stop(bridge)
    end
  end
end
