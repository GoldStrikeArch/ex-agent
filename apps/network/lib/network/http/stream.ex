defmodule Network.HTTP.Stream do
  @moduledoc """
  Streaming HTTP helpers for JSON POST requests.

  The transport owns request execution, worker lifecycle, timeouts, and status
  handling. Callers own stream state and response interpretation through
  callbacks.
  """

  @type request :: %{
          required(:url) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:body) => term(),
          optional(:json) => term(),
          optional(:timeout_ms) => pos_integer()
        }

  @type on_chunk(state) :: (binary(), state -> {:ok, state} | {:error, term()})
  @type on_success(state, result) :: (term(), state -> result)

  @default_timeout_ms 120_000

  @doc """
  Executes a JSON POST request and calls `:on_chunk` as response data arrives.

  The `:on_success` callback receives the final response body and latest stream
  state for any provider-specific flushing or decoding.
  """
  @spec post_json(request(), state, keyword()) ::
          result
          | {:error, {:network_response_failed, integer(), term()}}
          | {:error, {:network_request_failed, term()}}
          | {:error, {:network_stream_worker_unavailable, term()}}
          | {:error, :timeout}
        when state: term(), result: term()
  def post_json(request, initial_state, callbacks) when is_map(request) do
    with {:ok, on_chunk} <- callback(callbacks, :on_chunk, 2),
         {:ok, on_success} <- callback(callbacks, :on_success, 2),
         {:ok, worker} <- start_worker(request) do
      collect(worker, initial_state, on_chunk, on_success, timeout_ms(request))
    end
  end

  defp callback(callbacks, name, arity) do
    case Keyword.fetch(callbacks, name) do
      {:ok, fun} when is_function(fun, arity) -> {:ok, fun}
      {:ok, fun} -> {:error, {:invalid_stream_callback, name, fun}}
      :error -> {:error, {:missing_stream_callback, name}}
    end
  end

  defp start_worker(request) do
    owner = self()
    chunk_ref = make_ref()
    result_ref = make_ref()

    case Task.Supervisor.start_child(Network.TaskSupervisor, fn ->
           result = post_request(request, owner, chunk_ref)
           send(owner, {result_ref, result})
         end) do
      {:ok, pid} -> {:ok, worker(pid, chunk_ref, result_ref)}
      {:ok, pid, _info} -> {:ok, worker(pid, chunk_ref, result_ref)}
      {:error, reason} -> {:error, {:network_stream_worker_unavailable, reason}}
    end
  end

  defp worker(pid, chunk_ref, result_ref) do
    %{
      pid: pid,
      chunk_ref: chunk_ref,
      result_ref: result_ref,
      monitor_ref: Process.monitor(pid)
    }
  end

  defp post_request(request, owner, chunk_ref) do
    Req.post(
      url: Map.fetch!(request, :url),
      headers: Map.get(request, :headers, []),
      json: Map.get(request, :json, Map.get(request, :body)),
      receive_timeout: timeout_ms(request),
      into: fn {:data, data}, acc ->
        send(owner, {chunk_ref, :chunk, data})
        {:cont, acc}
      end
    )
  end

  defp collect(worker, state, on_chunk, on_success, timeout_ms) do
    receive do
      {ref, :chunk, chunk} when ref == worker.chunk_ref ->
        handle_chunk(chunk, worker, state, on_chunk, on_success, timeout_ms)

      {ref, result} when ref == worker.result_ref ->
        finish_result(result, worker, state, on_success)

      {:DOWN, ref, :process, _pid, reason} when ref == worker.monitor_ref ->
        {:error, {:network_request_failed, reason}}
    after
      timeout_ms ->
        stop_worker(worker, :timeout)
    end
  end

  defp handle_chunk(chunk, worker, state, on_chunk, on_success, timeout_ms) do
    case on_chunk.(chunk, state) do
      {:ok, next_state} -> collect(worker, next_state, on_chunk, on_success, timeout_ms)
      {:error, reason} -> stop_worker(worker, reason)
    end
  end

  defp finish_result(result, worker, state, on_success) do
    Process.demonitor(worker.monitor_ref, [:flush])

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        on_success.(body, state)

      {:ok, %{status: status, body: body}} ->
        {:error, {:network_response_failed, status, body}}

      {:error, reason} ->
        {:error, {:network_request_failed, reason}}
    end
  end

  defp stop_worker(worker, reason) do
    Process.exit(worker.pid, :kill)
    Process.demonitor(worker.monitor_ref, [:flush])
    {:error, reason}
  end

  defp timeout_ms(request), do: Map.get(request, :timeout_ms, @default_timeout_ms)
end
