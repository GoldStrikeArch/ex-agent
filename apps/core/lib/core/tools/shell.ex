defmodule Core.Tools.Shell do
  @moduledoc """
  Runs a shell command inside the workspace.
  """

  @behaviour Core.Tool

  alias Core.Tools.Args

  @default_max_output_bytes 64 * 1_024

  @impl true
  def name, do: "shell"

  @impl true
  def description, do: "Run a shell command in the workspace and return its combined output."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["command"],
      properties: %{
        command: %{type: "string"},
        timeout_ms: %{type: "integer"},
        max_output_bytes: %{type: "integer", default: @default_max_output_bytes}
      }
    }
  end

  @impl true
  def safety, do: :shell

  @impl true
  def run(args, context) do
    with {:ok, command} <- Args.fetch_string(args, :command),
         {:ok, timeout_ms} <- Args.optional_integer(args, :timeout_ms, 1, 600_000),
         {:ok, max_bytes} <-
           Args.integer(args, :max_output_bytes, @default_max_output_bytes, 0, 5_000_000),
         {:ok, shell} <- shell_path() do
      run_command(shell, command, context.workspace_root, timeout_ms, max_bytes)
    end
  end

  defp shell_path do
    case System.find_executable("sh") do
      nil -> {:error, :shell_not_found}
      shell -> {:ok, shell}
    end
  end

  defp run_command(shell, command, workspace_root, timeout_ms, max_bytes) do
    root = workspace_root |> Path.expand() |> Path.absname()
    port = open_port(shell, command, root)
    deadline = deadline(timeout_ms)
    capture = %{chunks: [], bytes: 0, max_bytes: max_bytes, truncated: false}

    case receive_port(port, deadline, timeout_ms, capture) do
      {:ok, exit_status, output, truncated} ->
        {:ok, result(command, exit_status, output, truncated)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_port(shell, command, root) do
    Port.open({:spawn_executable, shell}, [
      :binary,
      :exit_status,
      :hide,
      :stderr_to_stdout,
      {:args, ["-c", command]},
      {:cd, root}
    ])
  end

  defp receive_port(port, deadline, timeout_ms, capture) do
    receive do
      {^port, message} ->
        handle_port_message(message, port, deadline, timeout_ms, capture)
    after
      timeout_remaining(deadline) ->
        Port.close(port)
        {:error, {:shell_timeout, timeout_ms, capture_output(capture)}}
    end
  end

  defp handle_port_message({:data, data}, port, deadline, timeout_ms, capture) do
    receive_port(port, deadline, timeout_ms, capture_data(capture, data))
  end

  defp handle_port_message({:exit_status, exit_status}, _port, _deadline, _timeout_ms, capture) do
    {:ok, exit_status, capture_output(capture), capture.truncated}
  end

  defp deadline(nil), do: nil
  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp timeout_remaining(nil), do: :infinity

  defp timeout_remaining(deadline) do
    max(0, deadline - System.monotonic_time(:millisecond))
  end

  defp capture_data(%{bytes: bytes, max_bytes: max_bytes} = capture, _data)
       when bytes >= max_bytes do
    %{capture | truncated: true}
  end

  defp capture_data(%{max_bytes: max_bytes, bytes: bytes} = capture, data) do
    remaining = max_bytes - bytes
    capture_data(capture, data, remaining)
  end

  defp capture_data(capture, data, remaining) when byte_size(data) <= remaining do
    %{capture | chunks: [data | capture.chunks], bytes: capture.bytes + byte_size(data)}
  end

  defp capture_data(capture, data, remaining) do
    chunk = binary_part(data, 0, remaining)
    %{capture | chunks: [chunk | capture.chunks], bytes: capture.max_bytes, truncated: true}
  end

  defp capture_output(%{chunks: chunks}) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp result(command, exit_status, output, truncated) do
    %{
      command: command,
      exit_status: exit_status,
      output: output,
      truncated: truncated,
      summary: "exit #{exit_status}#{truncated_label(truncated)}"
    }
  end

  defp truncated_label(true), do: ", output truncated"
  defp truncated_label(false), do: ""
end
