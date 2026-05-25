defmodule Tui.TerminalApp do
  @moduledoc """
  Starts and controls the full-screen terminal UI runtime.

  The caller owns agent session lifecycle. This module only exposes the UI
  runtime and messages for injecting agent events and prompt submission
  callbacks.
  """

  alias Tui.TerminalApp.Root

  @type submit_prompt :: (String.t() -> term())
  @type command_context :: %{prompt: String.t()}
  @type command_handler :: (atom(), command_context() -> term())

  @doc """
  Runs the terminal UI until the runtime exits.

  Options:

    * `:submit_prompt` - callback invoked for user prompts.
    * `:initial_prompt` - optional text submitted after startup.
    * `:test_mode` - optional `{width, height}` headless terminal for tests.
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
  Starts an ExRatatui runtime for embedding or tests.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts
    |> Keyword.drop([:backend])
    |> Keyword.put_new(:name, nil)
    |> Keyword.put_new(:task_supervisor, Tui.TaskSupervisor)
    |> Root.start_link()
  end

  @doc """
  Forwards one agent event into the UI.
  """
  @spec send_event(GenServer.server(), tuple()) :: :ok
  def send_event(runtime, event) when is_tuple(event) do
    send(runtime, {:agent_event, event})
    :ok
  end

  @doc """
  Installs the prompt submission callback used by the UI.
  """
  @spec set_submit_prompt(GenServer.server(), submit_prompt()) :: :ok
  def set_submit_prompt(runtime, submit_prompt) when is_function(submit_prompt, 1) do
    send(runtime, {:set_submit_prompt, submit_prompt})
    :ok
  end

  @doc """
  Installs the app-owned slash command handler.
  """
  @spec set_command_handler(GenServer.server(), command_handler()) :: :ok
  def set_command_handler(runtime, command_handler) when is_function(command_handler, 2) do
    send(runtime, {:set_command_handler, command_handler})
    :ok
  end

  @doc """
  Appends an app-level notice to the transcript without creating model events.
  """
  @spec append_notice(GenServer.server(), String.t()) :: :ok
  def append_notice(runtime, text) when is_binary(text) do
    send(runtime, {:append_notice, text})
    :ok
  end

  @doc """
  Submits an initial prompt after startup.
  """
  @spec submit_initial(GenServer.server(), String.t()) :: :ok
  def submit_initial(runtime, prompt) when is_binary(prompt) do
    send(runtime, {:submit_initial, prompt})
    :ok
  end

  @doc """
  Requests graceful runtime shutdown.
  """
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(runtime) do
    GenServer.stop(runtime)
    :ok
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :shutdown -> :ok
    :exit, {:shutdown, _} -> :ok
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
