defmodule Network do
  @moduledoc """
  Generic networking primitives shared by provider and product apps.

  This app intentionally avoids provider schemas and agent concepts. It owns
  transport details such as streaming HTTP requests, WebSocket sessions, SSE
  framing, and temporary localhost callback servers.
  """
end
