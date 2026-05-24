defmodule Core.Auth.OAuth.CallbackServer do
  @moduledoc """
  Temporary localhost OAuth callback server.
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

    case Plug.Cowboy.http(__MODULE__, opts, ip: {127, 0, 0, 1}, port: port, ref: ref) do
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
    |> put_private(:oauth_callback_opts, opts)
    |> super(opts)
  end

  get "/auth/callback" do
    opts = conn.private.oauth_callback_opts
    expected_state = Map.fetch!(opts, :state)
    owner = Map.fetch!(opts, :owner)
    ref = Map.fetch!(opts, :ref)

    handle_callback(conn, owner, ref, expected_state)
  end

  match _ do
    conn
    |> put_resp_content_type("text/html")
    |> resp(404, html("Callback route not found."))
  end

  defp handle_callback(conn, owner, ref, expected_state) do
    result =
      conn
      |> fetch_query_params()
      |> Map.fetch!(:query_params)
      |> callback_result(expected_state)

    send_callback(owner, ref, result)
    callback_response(conn, result)
  end

  defp callback_result(%{"state" => state, "code" => code}, expected_state)
       when state == expected_state and is_binary(code) and code != "" do
    {:ok, code}
  end

  defp callback_result(%{"state" => state}, expected_state) when state == expected_state do
    {:error, :missing_code}
  end

  defp callback_result(_params, _expected_state), do: {:error, :state_mismatch}

  defp callback_response(conn, {:ok, _code}) do
    html_response(conn, 200, "OpenAI authentication completed. You can close this window.")
  end

  defp callback_response(conn, {:error, :state_mismatch}) do
    html_response(conn, 400, "State mismatch.")
  end

  defp callback_response(conn, {:error, :missing_code}) do
    html_response(conn, 400, "Missing authorization code.")
  end

  defp html_response(conn, status, message) do
    conn
    |> put_resp_content_type("text/html")
    |> resp(status, html(message))
  end

  defp send_callback(owner, ref, result) do
    send(owner, {:core_oauth_callback, ref, result})
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
    :"agent-core-oauth-#{System.unique_integer([:positive])}"
  end
end
