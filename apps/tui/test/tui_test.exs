defmodule TuiTest do
  use ExUnit.Case, async: true

  test "renders core events as append-only text" do
    assert IO.iodata_to_binary(Tui.TextRenderer.render({:user_message, "hello"})) ==
             "user> hello\n"

    assert IO.iodata_to_binary(Tui.TextRenderer.render({:assistant_delta, "message-1", "hi"})) ==
             "hi"
  end
end
