defmodule AgentTui.CLI do
  @moduledoc """
  Minimal command-line entrypoint for the TUI app.
  """

  @doc """
  Runs a one-shot prompt through the mock core session.
  """
  @spec main([String.t()]) :: :ok
  def main(args) do
    {:ok, _apps} = Application.ensure_all_started(:agent_core)
    {:ok, _renderer} = AgentTui.ConsoleRenderer.start_link([])

    args
    |> Enum.join(" ")
    |> String.trim()
    |> run_prompt()
  end

  defp run_prompt("") do
    IO.puts("agent_tui skeleton: pass a prompt as command arguments.")
    :ok
  end

  defp run_prompt(prompt) do
    {:ok, session} = AgentCore.start_session()
    {:ok, _reply} = AgentCore.send_message(session, prompt)
    :ok = AgentCore.stop_session(session)
    Process.sleep(20)
    :ok
  end
end
