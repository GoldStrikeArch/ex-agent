defmodule AgentCore.Auth.Credential do
  @moduledoc """
  Stored credential material for provider authentication.

  OAuth credentials store expiry as Unix milliseconds. Callers should treat the
  access and refresh values as secrets and only serialize them through
  `AgentCore.Auth.Storage`.
  """

  @enforce_keys [:access, :refresh, :expires_at, :account_id]
  defstruct type: :oauth,
            access: nil,
            refresh: nil,
            expires_at: nil,
            account_id: nil

  @type t :: %__MODULE__{
          type: :oauth,
          access: String.t(),
          refresh: String.t(),
          expires_at: integer(),
          account_id: String.t()
        }

  @doc """
  Returns true when the credential is expired or will expire within `skew_ms`.
  """
  @spec expired?(t(), integer(), non_neg_integer()) :: boolean()
  def expired?(credential, now_ms \\ System.system_time(:millisecond), skew_ms \\ 60_000)

  def expired?(%__MODULE__{expires_at: expires_at}, now_ms, skew_ms) do
    expires_at <= now_ms + skew_ms
  end

  @doc """
  Converts a credential to a JSON-serializable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = credential) do
    %{
      type: "oauth",
      access: credential.access,
      refresh: credential.refresh,
      expires_at: credential.expires_at,
      account_id: credential.account_id
    }
  end

  @doc """
  Parses a decoded JSON credential map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map) do
    with :oauth <- parse_type(value(map, :type, "oauth")),
         {:ok, access} <- string_field(map, :access),
         {:ok, refresh} <- string_field(map, :refresh),
         {:ok, expires_at} <- integer_field(map, :expires_at),
         {:ok, account_id} <- string_field(map, :account_id) do
      {:ok,
       %__MODULE__{
         access: access,
         refresh: refresh,
         expires_at: expires_at,
         account_id: account_id
       }}
    else
      {:error, reason} -> {:error, reason}
      type -> {:error, {:invalid_credential_type, type}}
    end
  end

  def from_map(value), do: {:error, {:invalid_credential, value}}

  defp parse_type("oauth"), do: :oauth
  defp parse_type(:oauth), do: :oauth
  defp parse_type(type), do: type

  defp string_field(map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_credential_field, key, value}}
    end
  end

  defp integer_field(map, key) do
    case value(map, key) do
      value when is_integer(value) -> {:ok, value}
      value -> {:error, {:invalid_credential_field, key, value}}
    end
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
