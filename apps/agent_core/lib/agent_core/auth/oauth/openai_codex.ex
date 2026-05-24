defmodule AgentCore.Auth.OAuth.OpenAICodex do
  @moduledoc """
  OpenAI Codex/ChatGPT OAuth provider.

  The login flow uses PKCE with a temporary localhost callback server. If the
  callback server cannot bind, callers can still complete login by pasting the
  authorization code or full redirect URL through the configured prompt
  callback.
  """

  @behaviour AgentCore.Auth.OAuth.Provider

  alias AgentCore.Auth.Credential
  alias AgentCore.Auth.OAuth.CallbackServer
  alias AgentCore.Auth.OAuth.PKCE
  alias AgentCore.Auth.Storage

  @authorize_url "https://auth.openai.com/oauth/authorize"
  @token_url "https://auth.openai.com/oauth/token"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @redirect_uri "http://localhost:1455/auth/callback"
  @scope "openid profile email offline_access"
  @jwt_claim_path "https://api.openai.com/auth"
  @callback_timeout_ms 120_000

  @impl true
  def login(opts \\ []) do
    callbacks = Keyword.get(opts, :callbacks, %{})
    flow = authorization_flow(opts)

    with {:ok, code} <- receive_authorization_code(flow, callbacks, opts),
         {:ok, credential} <- exchange_code(code, flow.verifier, opts),
         :ok <- Storage.write(:openai_codex, credential, opts) do
      {:ok, credential}
    end
  end

  @impl true
  def refresh(%Credential{} = credential, opts \\ []) do
    with {:ok, refreshed} <- refresh_token(credential.refresh, opts),
         :ok <- Storage.write(:openai_codex, refreshed, opts) do
      {:ok, refreshed}
    end
  end

  @impl true
  def access_token(%Credential{access: access}) when is_binary(access), do: {:ok, access}
  def access_token(credential), do: {:error, {:invalid_credential, credential}}

  @doc """
  Reads the stored credential and refreshes it if needed.
  """
  @spec resolve_credential(keyword()) :: {:ok, Credential.t()} | {:error, term()}
  def resolve_credential(opts \\ []) do
    with {:ok, credential} <- Storage.read(:openai_codex, opts) do
      if Credential.expired?(credential) do
        refresh(credential, opts)
      else
        {:ok, credential}
      end
    end
  end

  @doc """
  Builds the authorization URL and verifier state.
  """
  @spec authorization_flow(keyword()) :: map()
  def authorization_flow(opts \\ []) do
    pkce = PKCE.generate()
    state = create_state()
    redirect_uri = Keyword.get(opts, :redirect_uri, @redirect_uri)
    originator = Keyword.get(opts, :originator, "elixir-agent")

    url =
      @authorize_url
      |> URI.new!()
      |> URI.append_query(
        URI.encode_query(%{
          response_type: "code",
          client_id: @client_id,
          redirect_uri: redirect_uri,
          scope: @scope,
          code_challenge: pkce.challenge,
          code_challenge_method: "S256",
          state: state,
          id_token_add_organizations: "true",
          codex_cli_simplified_flow: "true",
          originator: originator
        })
      )
      |> URI.to_string()

    %{url: url, verifier: pkce.verifier, state: state, redirect_uri: redirect_uri}
  end

  @doc """
  Parses a pasted authorization code, full redirect URL, or `code#state` value.
  """
  @spec parse_authorization_input(String.t()) :: %{
          optional(:code) => String.t(),
          optional(:state) => String.t()
        }
  def parse_authorization_input(input) when is_binary(input) do
    input
    |> String.trim()
    |> parse_authorization_value()
  end

  defp parse_authorization_value(""), do: %{}

  defp parse_authorization_value(value) do
    cond do
      String.contains?(value, "://") -> parse_authorization_url(value)
      String.contains?(value, "#") -> parse_hash_code(value)
      String.contains?(value, "code=") -> parse_query(value)
      true -> %{code: value}
    end
  end

  @doc """
  Extracts the ChatGPT account id from an access-token JWT.
  """
  @spec extract_account_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_account_id(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- JSON.decode(decoded),
         account_id when is_binary(account_id) and account_id != "" <-
           get_in(claims, [@jwt_claim_path, "chatgpt_account_id"]) do
      {:ok, account_id}
    else
      _reason -> {:error, :account_id_not_found}
    end
  end

  def exchange_code(code, verifier, opts \\ []) when is_binary(code) and is_binary(verifier) do
    params = %{
      grant_type: "authorization_code",
      client_id: @client_id,
      code: code,
      code_verifier: verifier,
      redirect_uri: Keyword.get(opts, :redirect_uri, @redirect_uri)
    }

    params
    |> token_request(opts)
    |> credential_from_token_response()
  end

  def refresh_token(refresh_token, opts \\ []) when is_binary(refresh_token) do
    %{
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: @client_id
    }
    |> token_request(opts)
    |> credential_from_token_response()
  end

  defp receive_authorization_code(flow, callbacks, opts) do
    server = start_callback_server(flow.state, opts)
    notify_auth(callbacks, flow.url)

    try do
      server
      |> wait_for_callback(Keyword.get(opts, :callback_timeout_ms, @callback_timeout_ms))
      |> prompt_for_code_if_needed(callbacks)
      |> validate_authorization_code(flow.state)
    after
      stop_callback_server(server)
    end
  end

  defp start_callback_server(state, opts) do
    ref = :"agent-core-openai-codex-#{System.unique_integer([:positive])}"

    case CallbackServer.start_link(
           owner: self(),
           state: state,
           ref: ref,
           port: Keyword.get(opts, :callback_port, 1455)
         ) do
      {:ok, server} -> {:ok, server}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for_callback({:ok, %{ref: ref}}, timeout_ms) do
    receive do
      {:agent_core_oauth_callback, ^ref, {:ok, code}} -> {:ok, code}
      {:agent_core_oauth_callback, ^ref, {:error, reason}} -> {:error, reason}
    after
      timeout_ms -> {:error, :callback_timeout}
    end
  end

  defp wait_for_callback({:error, reason}, _timeout_ms),
    do: {:error, {:callback_server_unavailable, reason}}

  defp prompt_for_code_if_needed({:ok, code}, _callbacks), do: {:ok, code}

  defp prompt_for_code_if_needed({:error, _reason}, callbacks) do
    prompt = Map.get(callbacks, :on_prompt)

    if is_function(prompt, 1) do
      case prompt.(%{message: "Paste the authorization code or full redirect URL:"}) do
        {:ok, input} -> {:ok, input}
        {:error, reason} -> {:error, reason}
        input when is_binary(input) -> {:ok, input}
        other -> {:error, {:invalid_prompt_result, other}}
      end
    else
      {:error, :authorization_code_required}
    end
  end

  defp validate_authorization_code({:ok, input}, expected_state) do
    parsed = parse_authorization_input(input)

    cond do
      is_binary(parsed[:state]) and parsed.state != expected_state ->
        {:error, :state_mismatch}

      is_binary(parsed[:code]) and parsed.code != "" ->
        {:ok, parsed.code}

      true ->
        {:error, :missing_authorization_code}
    end
  end

  defp validate_authorization_code({:error, reason}, _expected_state), do: {:error, reason}

  defp stop_callback_server({:ok, %{ref: ref}}), do: CallbackServer.stop(ref)
  defp stop_callback_server(_server), do: :ok

  defp notify_auth(%{on_auth: on_auth}, url) when is_function(on_auth, 1) do
    on_auth.(%{
      url: url,
      instructions: "Open this URL, complete login, then return to the terminal."
    })
  end

  defp notify_auth(_callbacks, _url), do: :ok

  defp token_request(params, opts) do
    opts
    |> Keyword.get(:token_transport)
    |> request_token(params, opts)
  end

  defp request_token(transport, params, _opts) when is_function(transport, 1) do
    transport.(params)
  end

  defp request_token(_transport, params, opts) do
    Req.post(
      url: Keyword.get(opts, :token_url, @token_url),
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: URI.encode_query(params)
    )
  end

  defp credential_from_token_response({:ok, %{status: status, body: body}})
       when status in 200..299 do
    body
    |> decode_token_body()
    |> credential_from_token_map()
  end

  defp credential_from_token_response({:ok, %{status: status, body: body}}) do
    {:error, {:token_request_failed, status, body}}
  end

  defp credential_from_token_response({:error, reason}),
    do: {:error, {:token_request_failed, reason}}

  defp decode_token_body(%{} = body), do: {:ok, body}

  defp decode_token_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:error, {:invalid_token_response, decoded}}
      {:error, reason} -> {:error, {:invalid_token_response, reason}}
    end
  end

  defp decode_token_body(body), do: {:error, {:invalid_token_response, body}}

  defp credential_from_token_map({:ok, body}) do
    with {:ok, access} <- token_field(body, "access_token"),
         {:ok, refresh} <- token_field(body, "refresh_token"),
         {:ok, expires_in} <- token_integer(body, "expires_in"),
         {:ok, account_id} <- extract_account_id(access) do
      {:ok,
       %Credential{
         access: access,
         refresh: refresh,
         expires_at: System.system_time(:millisecond) + expires_in * 1000,
         account_id: account_id
       }}
    end
  end

  defp credential_from_token_map({:error, reason}), do: {:error, reason}

  defp token_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_token_field, key, value}}
    end
  end

  defp token_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> {:ok, value}
      value -> {:error, {:invalid_token_field, key, value}}
    end
  end

  defp create_state do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp parse_authorization_url(value) do
    uri = URI.parse(value)
    parse_query(uri.query || "")
  rescue
    URI.Error -> %{}
  end

  defp parse_query(query) do
    params = URI.decode_query(query)
    code = params["code"]
    state = params["state"]
    Map.reject(%{code: code, state: state}, fn {_key, value} -> is_nil(value) end)
  end

  defp parse_hash_code(value) do
    [code, state] = String.split(value, "#", parts: 2)
    Map.reject(%{code: code, state: state}, fn {_key, item} -> item in [nil, ""] end)
  end
end
