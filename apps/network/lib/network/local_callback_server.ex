defmodule Network.LocalCallbackServer do
  @moduledoc """
  Temporary localhost callback server for browser-based auth flows.

  The server validates an expected `state` query parameter, extracts a code
  query parameter, and sends `{message_tag, ref, result}` to the owner process.
  """

  use Plug.Router

  import Plug.Conn

  plug(:match)
  plug(:dispatch)

  @doc """
  Starts the callback server on `127.0.0.1`.
  """
  @spec start_link(keyword()) ::
          {:ok, %{pid: pid(), ref: atom(), port: :inet.port_number()}} | {:error, term()}
  def start_link(opts) do
    port = Keyword.get(opts, :port, 1455)
    ref = Keyword.get_lazy(opts, :ref, &new_ref/0)

    server_opts =
      opts
      |> Keyword.put_new(:path, "/auth/callback")
      |> Keyword.put_new(:message_tag, :network_local_callback)
      |> Keyword.put_new(:code_param, "code")
      |> Keyword.put_new(:state_param, "state")
      |> Keyword.put_new(:success_message, "Authentication completed. You can close this window.")

    case Plug.Cowboy.http(__MODULE__, server_opts, ip: {127, 0, 0, 1}, port: port, ref: ref) do
      {:ok, pid} -> {:ok, %{pid: pid, ref: ref, port: port}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a previously started callback server.
  """
  @spec stop(atom()) :: :ok
  def stop(ref) do
    Plug.Cowboy.shutdown(ref)
  catch
    :exit, _reason -> :ok
  end

  @impl Plug
  def init(opts), do: Map.new(opts)

  @impl Plug
  def call(conn, opts) do
    conn
    |> put_private(:local_callback_opts, opts)
    |> super(opts)
  end

  match _ do
    opts = conn.private.local_callback_opts

    if conn.method == "GET" and conn.request_path == Map.fetch!(opts, :path) do
      handle_callback(conn, opts)
    else
      html_response(conn, 404, "Callback route not found.")
    end
  end

  defp handle_callback(conn, opts) do
    result =
      conn
      |> fetch_query_params()
      |> Map.fetch!(:query_params)
      |> callback_result(opts)

    send_callback(opts, result)
    callback_response(conn, result, opts)
  end

  defp callback_result(params, opts) do
    state = Map.get(params, Map.fetch!(opts, :state_param))
    code = Map.get(params, Map.fetch!(opts, :code_param))

    cond do
      state != Map.fetch!(opts, :state) -> {:error, :state_mismatch}
      is_binary(code) and code != "" -> {:ok, code}
      true -> {:error, :missing_code}
    end
  end

  defp callback_response(conn, {:ok, _code}, opts) do
    html_response(conn, 200, Map.fetch!(opts, :success_message))
  end

  defp callback_response(conn, {:error, :state_mismatch}, _opts) do
    html_response(conn, 400, "State mismatch.")
  end

  defp callback_response(conn, {:error, :missing_code}, _opts) do
    html_response(conn, 400, "Missing authorization code.")
  end

  defp html_response(conn, status, message) do
    conn
    |> put_resp_content_type("text/html")
    |> resp(status, html(message))
  end

  defp send_callback(opts, result) do
    send(
      Map.fetch!(opts, :owner),
      {Map.fetch!(opts, :message_tag), Map.fetch!(opts, :ref), result}
    )
  end

  defp html(message) do
    """
    <!doctype html>
    <html>
      <body>
        <p>#{Plug.HTML.html_escape(message)}</p>
      </body>
    </html>
    """
  end

  defp new_ref do
    :"network-local-callback-#{System.unique_integer([:positive])}"
  end
end
