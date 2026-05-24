defmodule Network.HTTP do
  @moduledoc """
  Small HTTP request helpers shared by higher-level libraries.
  """

  @doc """
  Sends a form-encoded POST request.
  """
  @spec post_form(String.t(), map(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def post_form(url, params, opts \\ []) when is_binary(url) and is_map(params) do
    opts
    |> request_opts(url, params)
    |> Req.post()
  end

  defp request_opts(opts, url, params) do
    [
      url: url,
      headers:
        Keyword.get(opts, :headers, [{"content-type", "application/x-www-form-urlencoded"}]),
      body: URI.encode_query(params)
    ]
    |> maybe_put(:receive_timeout, Keyword.get(opts, :timeout_ms))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
