defmodule AgentApp.Interactive do
  @moduledoc """
  Owns the interactive terminal mode lifecycle.

  This module composes `Core` sessions with `Tui` rendering. The UI
  process is started before the core session so startup events are not missed.
  """

  alias AgentApp.EventBridge
  alias Tui.TerminalApp

  @doc """
  Runs an interactive terminal session.

  Options:

    * `:session_opts` - options passed to `Core.start_session/1`.
    * `:initial_prompt` - optional prompt submitted after session startup.
    * `:test_mode` - optional `{width, height}` headless TUI for tests.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started(:agent)

    {session_opts, tui_opts} = Keyword.pop(opts, :session_opts, [])

    case TerminalApp.start_link(tui_opts) do
      {:ok, runtime} ->
        start_bridge_and_session(
          runtime,
          session_opts,
          Keyword.get(tui_opts, :initial_prompt, "")
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_bridge_and_session(runtime, session_opts, initial_prompt) do
    case EventBridge.start_link(runtime: runtime) do
      {:ok, bridge} ->
        start_session_and_wait(runtime, bridge, session_opts, initial_prompt)

      {:error, reason} ->
        TerminalApp.shutdown(runtime)
        {:error, reason}
    end
  end

  defp start_session_and_wait(runtime, bridge, session_opts, initial_prompt) do
    case Core.start_session(session_opts) do
      {:ok, session} ->
        try do
          TerminalApp.set_submit_prompt(runtime, &Core.send_message(session, &1))
          maybe_submit_initial_prompt(runtime, initial_prompt)
          TerminalApp.wait(runtime)
        after
          stop_session(session)
          stop_bridge(bridge)
        end

      {:error, reason} ->
        TerminalApp.shutdown(runtime)
        stop_bridge(bridge)
        {:error, reason}
    end
  end

  defp maybe_submit_initial_prompt(_runtime, ""), do: :ok
  defp maybe_submit_initial_prompt(_runtime, nil), do: :ok

  defp maybe_submit_initial_prompt(runtime, prompt) when is_binary(prompt) do
    TerminalApp.submit_initial(runtime, prompt)
  end

  defp stop_session(session) do
    Core.stop_session(session)
  end

  defp stop_bridge(bridge) do
    if Process.alive?(bridge) do
      GenServer.stop(bridge)
    end
  end
end
