defmodule Network.LocalCallbackServerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  test "sends successful callback result to the owner" do
    opts = opts(state: "state-1", ref: :callback_ref)

    conn =
      :get
      |> conn("/auth/callback?code=code-1&state=state-1")
      |> Network.LocalCallbackServer.call(opts)

    assert conn.status == 200
    assert_receive {:network_local_callback, :callback_ref, {:ok, "code-1"}}
  end

  test "rejects mismatched state" do
    opts = opts(state: "state-1", ref: :callback_ref)

    conn =
      :get
      |> conn("/auth/callback?code=code-1&state=wrong")
      |> Network.LocalCallbackServer.call(opts)

    assert conn.status == 400
    assert_receive {:network_local_callback, :callback_ref, {:error, :state_mismatch}}
  end

  test "returns 404 for other routes" do
    opts = opts(state: "state-1", ref: :callback_ref)

    conn =
      :get
      |> conn("/other")
      |> Network.LocalCallbackServer.call(opts)

    assert conn.status == 404
    refute_receive {:network_local_callback, :callback_ref, _result}
  end

  defp opts(overrides) do
    overrides
    |> Keyword.merge(owner: self())
    |> Keyword.put_new(:path, "/auth/callback")
    |> Keyword.put_new(:message_tag, :network_local_callback)
    |> Keyword.put_new(:code_param, "code")
    |> Keyword.put_new(:state_param, "state")
    |> Keyword.put_new(:success_message, "Authentication completed. You can close this window.")
    |> Network.LocalCallbackServer.init()
  end
end
