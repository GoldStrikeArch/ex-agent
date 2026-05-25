defmodule Network.WebSocket.Stream do
  @moduledoc """
  Streaming WebSocket helpers for one text-frame request/response streams.

  The transport owns connection setup, reusable session sockets, timeouts,
  close frames, and ping/pong handling. Callers own JSON encoding/decoding and
  event interpretation through callbacks.
  """

  @type request :: %{
          required(:url) => String.t(),
          required(:text) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:cache_key) => term(),
          optional(:metadata) => term(),
          optional(:timeout_ms) => pos_integer(),
          optional(:idle_timeout_ms) => pos_integer(),
          optional(:connect_opts) => keyword(),
          optional(:websocket_opts) => keyword()
        }

  @type on_text(state) ::
          (String.t(), state ->
             {:cont, state}
             | {:halt, state, term()}
             | {:error, term()})

  @type on_success(state, result) :: (state, term() -> result)

  @doc """
  Sends `request.text` as one WebSocket text frame and streams text responses.

  `:on_text` receives every text frame and decides whether to continue or halt.
  On a halt, metadata is stored with the cached session connection, then
  `:on_success` receives the final caller state and metadata.
  """
  @spec post_text(request(), state, keyword()) ::
          result
          | {:error, {:network_websocket_failed, :before_start | :after_start, term()}}
          | {:error, term()}
        when state: term(), result: term()
  def post_text(request, initial_state, callbacks) when is_map(request) do
    with {:ok, on_text} <- callback(callbacks, :on_text, 2),
         {:ok, on_success} <- callback(callbacks, :on_success, 2),
         {:ok, state, metadata} <- execute(request, initial_state, on_text) do
      on_success.(state, metadata)
    end
  end

  @doc """
  Returns opaque metadata for a cached session, if one exists.
  """
  @spec metadata(term()) :: term() | nil
  def metadata(cache_key), do: Network.WebSocket.SessionPool.metadata(cache_key)

  @doc """
  Closes a cached session socket and clears its metadata.
  """
  @spec close(term()) :: :ok
  def close(cache_key), do: Network.WebSocket.SessionPool.close(cache_key)

  defp callback(callbacks, name, arity) do
    case Keyword.fetch(callbacks, name) do
      {:ok, fun} when is_function(fun, arity) -> {:ok, fun}
      {:ok, fun} -> {:error, {:invalid_stream_callback, name, fun}}
      :error -> {:error, {:missing_stream_callback, name}}
    end
  end

  @spec execute(request(), state, on_text(state)) ::
          {:ok, state, term()}
          | {:error, {:network_websocket_failed, :before_start | :after_start, term()}}
          | {:error, term()}
        when state: term()
  defp execute(%{cache_key: cache_key, url: url, text: text} = request, initial_state, on_text)
       when not is_nil(cache_key) and is_binary(url) and is_binary(text) do
    with {:ok, pid} <- Network.WebSocket.SessionPool.checkout(cache_key) do
      Network.WebSocket.Connection.request(pid, request, initial_state, on_text)
    end
  end

  defp execute(request, initial_state, on_text) do
    task =
      Task.Supervisor.async_nolink(Network.TaskSupervisor, fn ->
        Network.WebSocket.Connection.run_once(request, initial_state, on_text)
      end)

    case Task.yield(task, :infinity) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:network_websocket_failed, :before_start, reason}}
    end
  end
end
