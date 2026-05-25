defmodule Network.WebSocket.Connection do
  @moduledoc """
  Owns one Mint WebSocket connection and executes serialized text-frame streams.

  Provider-specific payload parsing stays in caller callbacks. This process owns
  connection reuse, close frames, ping/pong replies, idle expiry, and opaque
  metadata storage for the session using the socket.
  """

  use GenServer

  @default_timeout_ms 120_000
  @default_idle_timeout_ms 120_000

  defstruct cache_key: nil,
            conn: nil,
            websocket: nil,
            request_ref: nil,
            url: nil,
            headers: [],
            metadata: nil,
            idle_timer: nil

  @type request :: %{
          required(:url) => String.t(),
          required(:text) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:timeout_ms) => pos_integer(),
          optional(:idle_timeout_ms) => pos_integer(),
          optional(:connect_opts) => keyword(),
          optional(:websocket_opts) => keyword(),
          optional(:metadata) => term()
        }

  @type on_text(state) ::
          (String.t(), state ->
             {:cont, state}
             | {:halt, state, term()}
             | {:error, term()})

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :cache_key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc """
  Starts a reusable connection owner.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends one text frame and streams text frames through `on_text`.
  """
  @spec request(pid(), map(), state, on_text(state)) ::
          {:ok, state, term()}
          | {:error, {:network_websocket_failed, :before_start | :after_start, term()}}
        when state: term()
  def request(pid, request, initial_state, on_text)
      when is_pid(pid) and is_function(on_text, 2) do
    GenServer.call(pid, {:request, request, initial_state, on_text}, :infinity)
  end

  @doc """
  Runs a one-off WebSocket stream without caching the connection.
  """
  @spec run_once(map(), state, on_text(state)) ::
          {:ok, state, term()}
          | {:error, {:network_websocket_failed, :before_start | :after_start, term()}}
        when state: term()
  def run_once(request, initial_state, on_text) when is_function(on_text, 2) do
    state = %__MODULE__{}

    case execute_request(state, request, initial_state, on_text) do
      {:ok, result_state, metadata, next_state} ->
        close_socket(next_state)
        {:ok, result_state, metadata}

      {:error, reason, next_state} ->
        close_socket(next_state)
        {:error, reason}
    end
  end

  @doc """
  Returns the opaque metadata attached to this connection.
  """
  @spec metadata(pid()) :: term() | nil
  def metadata(pid), do: GenServer.call(pid, :metadata)

  @doc """
  Closes this connection and clears cached metadata.
  """
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.call(pid, :close)

  @impl true
  def init(opts), do: {:ok, %__MODULE__{cache_key: Keyword.get(opts, :cache_key)}}

  @impl true
  def handle_call(:metadata, _from, state), do: {:reply, state.metadata, state}

  def handle_call(:close, _from, state) do
    state = state |> cancel_idle() |> close_socket()
    {:reply, :ok, %{state | metadata: nil}}
  end

  def handle_call({:request, request, initial_state, on_text}, _from, state) do
    state = cancel_idle(state)

    case execute_request(state, request, initial_state, on_text) do
      {:ok, result_state, metadata, next_state} ->
        next_state =
          next_state
          |> Map.put(:metadata, metadata)
          |> schedule_idle(request)

        {:reply, {:ok, result_state, metadata}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, %{close_socket(next_state) | metadata: nil}}
    end
  end

  @impl true
  def handle_info(:idle_expired, state), do: {:noreply, %{close_socket(state) | metadata: nil}}

  def handle_info(message, %{conn: nil} = state) do
    {:noreply, state, {:continue, {:discard_message, message}}}
  end

  def handle_info(message, state) do
    {:noreply, handle_idle_message(state, message)}
  end

  @impl true
  def handle_continue({:discard_message, _message}, state), do: {:noreply, state}

  defp execute_request(state, request, initial_stream_state, on_text) do
    with {:ok, state} <- ensure_connection(state, request),
         {:ok, state} <- send_text(state, Map.fetch!(request, :text)) do
      case collect_frames(state, initial_stream_state, on_text, timeout_ms(request), false) do
        {:ok, result_state, metadata, next_state} ->
          {:ok, result_state, metadata, next_state}

        {:error, phase, reason, next_state} ->
          {:error, {:network_websocket_failed, phase, reason}, next_state}
      end
    else
      {:error, reason, next_state} ->
        {:error, {:network_websocket_failed, :before_start, reason}, next_state}
    end
  end

  defp ensure_connection(%{conn: nil} = state, request), do: connect(state, request)

  defp ensure_connection(state, request) do
    if same_connection?(state, request) do
      {:ok, state}
    else
      state
      |> close_socket()
      |> connect(request)
    end
  end

  defp same_connection?(state, request) do
    state.url == Map.fetch!(request, :url) and state.headers == Map.get(request, :headers, [])
  end

  defp connect(state, request) do
    with {:ok, parts} <- websocket_parts(Map.fetch!(request, :url)),
         {:ok, conn} <-
           Mint.HTTP.connect(parts.http_scheme, parts.host, parts.port, connect_opts(request)),
         {:ok, conn, request_ref} <-
           Mint.WebSocket.upgrade(
             parts.ws_scheme,
             conn,
             parts.path,
             Map.get(request, :headers, []),
             Map.get(request, :websocket_opts, [])
           ),
         {:ok, conn, websocket} <- await_upgrade(conn, request_ref, timeout_ms(request)) do
      {:ok,
       %{
         state
         | conn: conn,
           websocket: websocket,
           request_ref: request_ref,
           url: Map.fetch!(request, :url),
           headers: Map.get(request, :headers, [])
       }}
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp connect_opts(request) do
    request
    |> Map.get(:connect_opts, [])
    |> Keyword.put_new(:mode, :active)
  end

  defp await_upgrade(conn, request_ref, timeout_ms) do
    with {:ok, conn, status, headers} <-
           await_upgrade_response(conn, request_ref, timeout_ms, nil, []) do
      new_websocket(conn, request_ref, status, headers)
    end
  end

  @spec new_websocket(
          Mint.HTTP.t(),
          Mint.Types.request_ref(),
          Mint.Types.status(),
          Mint.Types.headers()
        ) ::
          {:ok, Mint.HTTP.t(), Mint.WebSocket.t()}
          | {:error, Mint.HTTP.t(), Mint.WebSocket.error()}
  defp new_websocket(conn, request_ref, status, headers) do
    apply(Mint.WebSocket, :new, [conn, request_ref, status, headers])
  end

  @spec await_upgrade_response(
          Mint.HTTP.t(),
          Mint.Types.request_ref(),
          timeout(),
          Mint.Types.status() | nil,
          Mint.Types.headers()
        ) ::
          {:ok, Mint.HTTP.t(), Mint.Types.status(), Mint.Types.headers()}
          | {:error, Mint.HTTP.t(), term()}
  defp await_upgrade_response(conn, request_ref, timeout_ms, status, headers) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            {status, headers, done?} = upgrade_parts(responses, request_ref, status, headers)

            handle_upgrade_progress(done?, conn, request_ref, timeout_ms, status, headers)

          {:error, conn, reason, _responses} ->
            {:error, conn, reason}

          :unknown ->
            await_upgrade_response(conn, request_ref, timeout_ms, status, headers)
        end
    after
      timeout_ms ->
        {:error, conn, :timeout}
    end
  end

  defp handle_upgrade_progress(true, conn, _request_ref, _timeout_ms, status, headers) do
    with {:ok, status} <- normalize_status(status),
         {:ok, headers} <- normalize_headers(headers) do
      {:ok, conn, status, headers}
    else
      :error -> {:error, conn, {:invalid_websocket_upgrade, status, headers}}
    end
  end

  defp handle_upgrade_progress(false, conn, request_ref, timeout_ms, status, headers) do
    await_upgrade_response(conn, request_ref, timeout_ms, status, headers)
  end

  @spec normalize_status(term()) :: {:ok, Mint.Types.status()} | :error
  defp normalize_status(status) when is_integer(status), do: {:ok, status}
  defp normalize_status(_status), do: :error

  @spec normalize_headers(term()) :: {:ok, Mint.Types.headers()} | :error
  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.reduce_while([], fn
      {key, value}, acc when is_binary(key) and is_binary(value) ->
        {:cont, [{key, value} | acc]}

      _header, _acc ->
        {:halt, :error}
    end)
    |> case do
      :error -> :error
      normalized -> {:ok, Enum.reverse(normalized)}
    end
  end

  defp normalize_headers(_headers), do: :error

  defp upgrade_parts(responses, request_ref, status, headers) do
    Enum.reduce(responses, {status, headers, false}, fn
      {:status, ^request_ref, next_status}, {_status, headers, done?} ->
        {next_status, headers, done?}

      {:headers, ^request_ref, next_headers}, {status, _headers, done?} ->
        {status, next_headers, done?}

      {:done, ^request_ref}, {status, headers, _done?} ->
        {status, headers, true}

      _response, acc ->
        acc
    end)
  end

  defp send_text(state, text) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, {:text, text}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, _resource, reason} -> {:error, reason, state}
    end
  end

  defp collect_frames(state, stream_state, on_text, timeout_ms, saw_text?) do
    receive do
      message ->
        case Mint.WebSocket.stream(state.conn, message) do
          {:ok, conn, responses} ->
            next_state = %{state | conn: conn}
            handle_responses(responses, next_state, stream_state, on_text, timeout_ms, saw_text?)

          {:error, conn, reason, _responses} ->
            {:error, phase(saw_text?), reason, %{state | conn: conn}}

          :unknown ->
            collect_frames(state, stream_state, on_text, timeout_ms, saw_text?)
        end
    after
      timeout_ms ->
        {:error, phase(saw_text?), :timeout, state}
    end
  end

  defp handle_responses([], state, stream_state, on_text, timeout_ms, saw_text?) do
    collect_frames(state, stream_state, on_text, timeout_ms, saw_text?)
  end

  defp handle_responses(
         [{:data, ref, data} | rest],
         state,
         stream_state,
         on_text,
         timeout_ms,
         saw_text?
       )
       when ref == state.request_ref do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        handle_frames(frames, rest, state, stream_state, on_text, timeout_ms, saw_text?)

      {:error, websocket, reason} ->
        {:error, phase(saw_text?), reason, %{state | websocket: websocket}}
    end
  end

  defp handle_responses(
         [{:done, ref} | _rest],
         state,
         _stream_state,
         _on_text,
         _timeout_ms,
         saw_text?
       )
       when ref == state.request_ref do
    {:error, phase(saw_text?), :closed, close_socket(state)}
  end

  defp handle_responses([_response | rest], state, stream_state, on_text, timeout_ms, saw_text?) do
    handle_responses(rest, state, stream_state, on_text, timeout_ms, saw_text?)
  end

  defp handle_frames([], rest, state, stream_state, on_text, timeout_ms, saw_text?) do
    handle_responses(rest, state, stream_state, on_text, timeout_ms, saw_text?)
  end

  defp handle_frames(
         [{:text, text} | frames],
         rest,
         state,
         stream_state,
         on_text,
         timeout_ms,
         _saw_text?
       ) do
    case on_text.(text, stream_state) do
      {:cont, next_stream_state} ->
        handle_frames(frames, rest, state, next_stream_state, on_text, timeout_ms, true)

      {:halt, next_stream_state, metadata} ->
        {:ok, next_stream_state, metadata, state}

      {:error, reason} ->
        {:error, :after_start, reason, state}
    end
  end

  defp handle_frames(
         [{:ping, data} | frames],
         rest,
         state,
         stream_state,
         on_text,
         timeout_ms,
         saw_text?
       ) do
    with {:ok, websocket, frame} <- Mint.WebSocket.encode(state.websocket, {:pong, data}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, frame) do
      state = %{state | websocket: websocket, conn: conn}
      handle_frames(frames, rest, state, stream_state, on_text, timeout_ms, saw_text?)
    else
      {:error, _resource, reason} ->
        {:error, phase(saw_text?), reason, state}
    end
  end

  defp handle_frames(
         [{:pong, _data} | frames],
         rest,
         state,
         stream_state,
         on_text,
         timeout_ms,
         saw_text?
       ) do
    handle_frames(frames, rest, state, stream_state, on_text, timeout_ms, saw_text?)
  end

  defp handle_frames(
         [{:close, code, reason} | _frames],
         _rest,
         state,
         _stream_state,
         _on_text,
         _timeout_ms,
         saw_text?
       ) do
    {:error, phase(saw_text?), {:closed, code, reason}, acknowledge_close(state)}
  end

  defp handle_frames(
         [{:binary, _data} | _frames],
         _rest,
         state,
         _stream_state,
         _on_text,
         _timeout_ms,
         saw_text?
       ) do
    {:error, phase(saw_text?), {:unexpected_frame, :binary}, state}
  end

  defp handle_frames(
         [{:error, reason} | _frames],
         _rest,
         state,
         _stream_state,
         _on_text,
         _timeout_ms,
         saw_text?
       ) do
    {:error, phase(saw_text?), reason, state}
  end

  defp handle_idle_message(state, message) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state
        |> Map.put(:conn, conn)
        |> handle_idle_responses(responses)

      {:error, conn, _reason, _responses} ->
        %{close_socket(%{state | conn: conn}) | metadata: nil}

      :unknown ->
        state
    end
  end

  defp handle_idle_responses(state, responses) do
    Enum.reduce(responses, state, fn
      {:data, ref, data}, next_state when ref == next_state.request_ref ->
        handle_idle_data(next_state, data)

      {:done, ref}, next_state when ref == next_state.request_ref ->
        %{close_socket(next_state) | metadata: nil}

      _response, next_state ->
        next_state
    end)
  end

  defp handle_idle_data(state, data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state
        |> Map.put(:websocket, websocket)
        |> handle_idle_frames(frames)

      {:error, websocket, _reason} ->
        %{close_socket(%{state | websocket: websocket}) | metadata: nil}
    end
  end

  defp handle_idle_frames(state, frames) do
    Enum.reduce_while(frames, state, fn
      {:ping, data}, next_state ->
        {:cont, send_pong(next_state, data)}

      {:pong, _data}, next_state ->
        {:cont, next_state}

      {:close, _code, _reason}, next_state ->
        {:halt, %{acknowledge_close(next_state) | metadata: nil}}

      _frame, next_state ->
        {:cont, next_state}
    end)
  end

  defp send_pong(state, data) do
    with {:ok, websocket, frame} <- Mint.WebSocket.encode(state.websocket, {:pong, data}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, frame) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, _resource, _reason} -> %{close_socket(state) | metadata: nil}
    end
  end

  defp acknowledge_close(state) do
    state
    |> send_close_frame()
    |> close_socket()
  end

  defp send_close_frame(%{conn: nil} = state), do: state

  defp send_close_frame(state) do
    with {:ok, websocket, frame} <- Mint.WebSocket.encode(state.websocket, :close),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, frame) do
      %{state | websocket: websocket, conn: conn}
    else
      _error -> state
    end
  end

  defp close_socket(%{conn: nil} = state), do: %{state | websocket: nil, request_ref: nil}

  defp close_socket(state) do
    Mint.HTTP.close(state.conn)
    %{state | conn: nil, websocket: nil, request_ref: nil, url: nil, headers: [], idle_timer: nil}
  end

  defp cancel_idle(%{idle_timer: nil} = state), do: state

  defp cancel_idle(state) do
    Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil}
  end

  defp schedule_idle(state, request) do
    timeout_ms = Map.get(request, :idle_timeout_ms, @default_idle_timeout_ms)
    timer = Process.send_after(self(), :idle_expired, timeout_ms)
    %{state | idle_timer: timer}
  end

  defp websocket_parts(url) do
    uri = URI.parse(url)

    with {:ok, ws_scheme, http_scheme} <- schemes(uri.scheme),
         {:ok, host} <- host(uri) do
      {:ok,
       %{
         ws_scheme: ws_scheme,
         http_scheme: http_scheme,
         host: host,
         port: uri.port || default_port(ws_scheme),
         path: path(uri)
       }}
    end
  end

  defp schemes("ws"), do: {:ok, :ws, :http}
  defp schemes("wss"), do: {:ok, :wss, :https}
  defp schemes(scheme), do: {:error, {:unsupported_websocket_scheme, scheme}}

  defp host(%URI{host: host}) when is_binary(host) and host != "", do: {:ok, host}
  defp host(uri), do: {:error, {:invalid_websocket_url, URI.to_string(uri)}}

  defp default_port(:ws), do: 80
  defp default_port(:wss), do: 443

  defp path(%URI{path: nil, query: nil}), do: "/"
  defp path(%URI{path: nil, query: query}), do: "/?" <> query
  defp path(%URI{path: "", query: nil}), do: "/"
  defp path(%URI{path: "", query: query}), do: "/?" <> query
  defp path(%URI{path: path, query: nil}), do: path
  defp path(%URI{path: path, query: query}), do: path <> "?" <> query

  defp timeout_ms(request), do: Map.get(request, :timeout_ms, @default_timeout_ms)
  defp phase(true), do: :after_start
  defp phase(false), do: :before_start
end
