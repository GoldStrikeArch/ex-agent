defmodule Network.SSETest do
  use ExUnit.Case, async: true

  test "parses complete data frames" do
    assert {:ok, ["one", "two"], %Network.SSE{buffer: ""}} =
             Network.SSE.parse_chunk(Network.SSE.new(), "data: one\n\ndata: two\n\n")
  end

  test "keeps partial frames until the next chunk" do
    assert {:ok, [], state} = Network.SSE.parse_chunk(Network.SSE.new(), "data: hel")
    assert %Network.SSE{buffer: "data: hel"} = state

    assert {:ok, ["hello"], %Network.SSE{buffer: ""}} =
             Network.SSE.parse_chunk(state, "lo\n\n")
  end

  test "joins multi-line data payloads" do
    assert {:ok, ["one\ntwo"], %Network.SSE{buffer: ""}} =
             Network.SSE.parse_chunk(Network.SSE.new(), "event: msg\ndata: one\ndata: two\n\n")
  end

  test "flushes a final partial frame" do
    assert {:ok, [], state} = Network.SSE.parse_chunk(Network.SSE.new(), "data: final")

    assert {:ok, ["final"], %Network.SSE{buffer: ""}} = Network.SSE.flush(state)
  end
end
