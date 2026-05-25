defmodule Network.WebSocket.StreamTest do
  use ExUnit.Case, async: false

  defmodule Handler do
    def init(req, parent), do: {:cowboy_websocket, req, parent}
    def websocket_init(parent), do: {:ok, parent}

    def websocket_handle({:text, "timeout"}, parent), do: {:ok, parent}

    def websocket_handle({:text, "close"}, parent) do
      {:reply, {:close, 1000, "bye"}, parent}
    end

    def websocket_handle({:text, text}, parent) do
      send(parent, {:server_text, self(), text})
      {:reply, [{:ping, "abc"}, {:text, text}], parent}
    end

    def websocket_handle({:pong, "abc"}, parent) do
      send(parent, {:server_pong, self()})
      {:ok, parent}
    end

    def websocket_handle(_frame, parent), do: {:ok, parent}
    def websocket_info(_message, parent), do: {:ok, parent}
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:network)

    ref = :"network_ws_stream_test_#{System.unique_integer([:positive])}"

    dispatch =
      :cowboy_router.compile([
        {:_, [{"/ws", Handler, self()}]}
      ])

    {:ok, _pid} = :cowboy.start_clear(ref, [{:port, 0}], %{env: %{dispatch: dispatch}})
    port = :ranch.get_port(ref)

    on_exit(fn ->
      :cowboy.stop_listener(ref)
    end)

    {:ok, url: "ws://127.0.0.1:#{port}/ws"}
  end

  test "sends a text frame, handles ping/pong, and returns streamed text", %{url: url} do
    assert {:ok, "hello", %{done: true}} =
             Network.WebSocket.Stream.post_text(
               %{url: url, text: "hello", timeout_ms: 1_000},
               "",
               on_text: fn text, acc -> {:halt, acc <> text, %{done: true}} end,
               on_success: fn acc, metadata -> {:ok, acc, metadata} end
             )

    assert_receive {:server_text, server_pid, "hello"}
    assert_receive {:server_pong, ^server_pid}
  end

  test "reports close frames before any text as before_start errors", %{url: url} do
    assert {:error, {:network_websocket_failed, :before_start, {:closed, 1000, "bye"}}} =
             Network.WebSocket.Stream.post_text(
               %{url: url, text: "close", timeout_ms: 1_000},
               "",
               on_text: fn text, acc -> {:halt, acc <> text, nil} end,
               on_success: fn acc, _metadata -> {:ok, acc} end
             )
  end

  test "reports timeouts before any text", %{url: url} do
    assert {:error, {:network_websocket_failed, :before_start, :timeout}} =
             Network.WebSocket.Stream.post_text(
               %{url: url, text: "timeout", timeout_ms: 20},
               "",
               on_text: fn text, acc -> {:halt, acc <> text, nil} end,
               on_success: fn acc, _metadata -> {:ok, acc} end
             )
  end

  test "reports connection failures", %{url: _url} do
    assert {:error, {:network_websocket_failed, :before_start, _reason}} =
             Network.WebSocket.Stream.post_text(
               %{url: "ws://127.0.0.1:1/ws", text: "hello", timeout_ms: 200},
               "",
               on_text: fn text, acc -> {:halt, acc <> text, nil} end,
               on_success: fn acc, _metadata -> {:ok, acc} end
             )
  end

  test "reuses session sockets, preserves metadata, and closes cached sessions", %{url: url} do
    cache_key = {:ws_stream_test, self(), System.unique_integer([:positive])}

    assert {:ok, "one", %{turn: 1}} =
             Network.WebSocket.Stream.post_text(
               %{
                 url: url,
                 text: "one",
                 cache_key: cache_key,
                 timeout_ms: 1_000,
                 idle_timeout_ms: 30
               },
               "",
               on_text: fn text, acc -> {:halt, acc <> text, %{turn: 1}} end,
               on_success: fn acc, metadata -> {:ok, acc, metadata} end
             )

    assert_receive {:server_text, server_pid, "one"}
    assert Network.WebSocket.Stream.metadata(cache_key) == %{turn: 1}

    assert {:ok, "two", %{turn: 2}} =
             Network.WebSocket.Stream.post_text(
               %{
                 url: url,
                 text: "two",
                 cache_key: cache_key,
                 timeout_ms: 1_000,
                 idle_timeout_ms: 30
               },
               "",
               on_text: fn text, acc -> {:halt, acc <> text, %{turn: 2}} end,
               on_success: fn acc, metadata -> {:ok, acc, metadata} end
             )

    assert_receive {:server_text, ^server_pid, "two"}
    assert Network.WebSocket.Stream.metadata(cache_key) == %{turn: 2}

    assert :ok = Network.WebSocket.Stream.close(cache_key)
    assert Network.WebSocket.Stream.metadata(cache_key) == nil
  end

  test "idle expiry closes the socket and clears metadata", %{url: url} do
    cache_key = {:ws_stream_idle_test, self(), System.unique_integer([:positive])}

    assert {:ok, "idle", %{turn: 1}} =
             Network.WebSocket.Stream.post_text(
               %{
                 url: url,
                 text: "idle",
                 cache_key: cache_key,
                 timeout_ms: 1_000,
                 idle_timeout_ms: 10
               },
               "",
               on_text: fn text, acc -> {:halt, acc <> text, %{turn: 1}} end,
               on_success: fn acc, metadata -> {:ok, acc, metadata} end
             )

    assert Network.WebSocket.Stream.metadata(cache_key) == %{turn: 1}
    Process.sleep(30)
    assert Network.WebSocket.Stream.metadata(cache_key) == nil
  end
end
