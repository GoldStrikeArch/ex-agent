defmodule Network.HTTP.StreamTest do
  use ExUnit.Case, async: true

  test "returns streamed non-success response bodies" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":"bad request"}))
    end

    assert {:error, {:network_response_failed, 400, ~s({"error":"bad request"})}} =
             Network.HTTP.Stream.post_json(
               %{
                 url: "http://example.test/responses",
                 body: %{model: "bad"},
                 req_opts: [plug: plug]
               },
               :state,
               on_chunk: fn _chunk, state -> {:ok, state} end,
               on_success: fn _body, state -> {:ok, state} end
             )
  end
end
