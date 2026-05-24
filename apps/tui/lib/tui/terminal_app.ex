defmodule Tui.TerminalApp do
  @moduledoc """
  Starts and controls the full-screen terminal UI runtime.

  The caller owns agent session lifecycle. This module only exposes the UI
  runtime and messages for injecting agent events and prompt submission
  callbacks.
  """

  alias Tui.TerminalApp.Root

  @type submit_prompt :: (String.t() -> term())

  @doc """
  Runs the terminal UI until the runtime exits.

  Options:

    * `:submit_prompt` - callback invoked for user prompts.
    * `:initial_prompt` - optional text submitted after startup.
    * `:backend` - TermUI backend selection, defaults to `:auto`.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started(:tui)

    case start_link(opts) do
      {:ok, runtime} ->
        maybe_submit_initial_prompt(runtime, Keyword.get(opts, :initial_prompt, ""))
        wait(runtime)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts a TermUI runtime for embedding or tests.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts
    |> Keyword.put(:root, Root)
    |> Keyword.put_new(:backend, :auto)
    |> Keyword.put_new(:task_supervisor, Tui.TaskSupervisor)
    |> TermUI.Runtime.start_link()
  end

  @doc """
  Forwards one agent event into the UI.
  """
  @spec send_event(GenServer.server(), tuple()) :: :ok
  def send_event(runtime, event) when is_tuple(event) do
    TermUI.Runtime.send_message(runtime, :root, {:agent_event, event})
  end

  @doc """
  Installs the prompt submission callback used by the UI.
  """
  @spec set_submit_prompt(GenServer.server(), submit_prompt()) :: :ok
  def set_submit_prompt(runtime, submit_prompt) when is_function(submit_prompt, 1) do
    TermUI.Runtime.send_message(runtime, :root, {:set_submit_prompt, submit_prompt})
  end

  @doc """
  Submits an initial prompt after startup.
  """
  @spec submit_initial(GenServer.server(), String.t()) :: :ok
  def submit_initial(runtime, prompt) when is_binary(prompt) do
    TermUI.Runtime.send_message(runtime, :root, {:submit_initial, prompt})
  end

  @doc """
  Requests graceful runtime shutdown.
  """
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(runtime) do
    TermUI.Runtime.shutdown(runtime)
  end

  @doc """
  Blocks until a runtime process exits.
  """
  @spec wait(pid()) :: :ok
  def wait(runtime) when is_pid(runtime) do
    ref = Process.monitor(runtime)

    receive do
      {:DOWN, ^ref, :process, ^runtime, _reason} -> :ok
    end
  end

  defp maybe_submit_initial_prompt(_runtime, ""), do: :ok
  defp maybe_submit_initial_prompt(_runtime, nil), do: :ok
  defp maybe_submit_initial_prompt(runtime, prompt), do: submit_initial(runtime, prompt)
end
