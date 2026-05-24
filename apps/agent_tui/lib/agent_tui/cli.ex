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

    case args do
      ["--replay", path] ->
        AgentTui.Replay.render_file(path)

      _args ->
        {:ok, _apps} = Application.ensure_all_started(:owl)
        {:ok, _renderer} = AgentTui.ConsoleRenderer.start_link([])
        {:ok, _status} = AgentTui.LiveStatus.start_link([])
        {:ok, session} = AgentCore.start_session()

        args
        |> Enum.join(" ")
        |> String.trim()
        |> run_session(session)
    end
  end

  defp run_session("", session) do
    try do
      AgentTui.InputLoop.run(session)
    after
      stop_session(session)
    end
  end

  defp run_session(prompt, session) do
    try do
      AgentTui.InputLoop.submit_prompt(session, prompt)
      Process.sleep(20)
      :ok
    after
      stop_session(session)
    end
  end

  defp stop_session(session) do
    AgentCore.stop_session(session)

    if Process.whereis(Owl.LiveScreen) do
      Owl.LiveScreen.flush()
    end
  end
end
