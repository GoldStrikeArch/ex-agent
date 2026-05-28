defmodule AgentApp.ModelCatalog do
  @moduledoc """
  Model options exposed by the runnable agent app.
  """

  @type option :: %{
          id: :openai_codex,
          label: String.t(),
          model: String.t(),
          provider: :openai_codex,
          settings_provider: String.t(),
          auth_provider: :openai_codex,
          client: module(),
          credential_resolver: function(),
          instructions: String.t(),
          text_verbosity: String.t(),
          thinking_level: String.t() | nil,
          thinking_levels: [String.t()],
          permission_mode: Core.PermissionPolicy.mode()
        }

  @auth_context_keys [:agent_dir, :path, :token_transport, :token_url]
  @default_instructions """
  You are a coding agent running in a local workspace.
  This experimental build exposes only structural code-intelligence tools.

  Start with index_status. If the index is empty or stale, run index_repo once before code navigation. Use indexed_outline for a recursive path-scoped map, indexed_files only when you need file paths, read_indexed_file when the user asks to read whole files, ast_outline for one known file, symbol_search and definitions with the path argument to find declarations, callers with the path argument to inspect references, ast_query for compact structural patterns, and fetch_node with exact id values returned by structural tools for focused source slices.

  Parallelize independent structural lookups. Whenever you need more than one read_indexed_file, symbol_search, definitions, callers, ast_outline, ast_query, or fetch_node call, emit them as sibling tool calls in the same assistant response. Prefer one indexed_outline call over many ast_outline calls when exploring a directory. Do not request structural lookups one at a time across multiple turns when they are independent.

  Do not invent symbol ids. Use the id= values returned by symbol_search, definitions, indexed_outline, ast_query, and ast_outline. Do not ask for shell, grep, list_files, read_file, edit_file, write_file, or batch; they are intentionally unavailable in this structural-only experiment. Because mutating tools are hidden, explain required code changes instead of attempting edits. Keep responses concise and grounded in structural results.
  """

  @doc """
  Returns every selectable model option.
  """
  @spec all() :: [option()]
  def all, do: [openai_codex()]

  @doc """
  Returns the default model option.
  """
  @spec default() :: option()
  def default, do: openai_codex()

  @doc """
  Finds a catalog option by provider and model.

  Provider values may be atoms from internal callers or strings loaded from
  settings. Unknown providers are not converted to atoms.
  """
  @spec fetch(atom() | String.t(), String.t()) :: {:ok, option()} | {:error, term()}
  def fetch(provider, model) when is_binary(model) do
    model = canonical_model(provider, model)

    case Enum.find(all(), &option_matches?(&1, provider, model)) do
      nil -> {:error, {:unknown_model, provider, model}}
      option -> {:ok, option}
    end
  end

  @doc """
  Returns the supported thinking levels for selectable models.
  """
  @spec thinking_levels() :: [String.t()]
  def thinking_levels, do: LLM.Thinking.levels()

  @doc """
  Returns a copy of `option` with a normalized thinking level.
  """
  @spec with_thinking_level(option(), term()) :: {:ok, option()} | {:error, term()}
  def with_thinking_level(option, level) do
    with {:ok, normalized} <- LLM.Thinking.normalize(level) do
      {:ok, %{option | thinking_level: normalized}}
    end
  end

  @doc """
  Converts a catalog option into a compact status payload for the TUI.
  """
  @spec status_info(option()) :: map()
  def status_info(option) do
    %{
      label: option.label,
      provider: option.provider,
      model: option.model,
      thinking_level: option.thinking_level
    }
  end

  @doc """
  Converts a catalog option into `Core.configure_model/2` options.
  """
  @spec core_opts(option(), keyword()) :: keyword()
  def core_opts(option, auth_opts \\ []) do
    [
      model_client: option.client,
      model_opts:
        ([
           model: option.model,
           provider: option.provider,
           auth_provider: option.auth_provider,
           credential_resolver: option.credential_resolver,
           instructions: option.instructions,
           text_verbosity: option.text_verbosity,
           reasoning_effort: option.thinking_level
         ] ++ auth_context_opts(auth_opts))
        |> Enum.reject(fn {_key, value} -> is_nil(value) end),
      permission_mode: option.permission_mode
    ]
  end

  defp option_matches?(option, provider, model) do
    provider_matches?(option.provider, provider) and option.model == model
  end

  defp provider_matches?(provider, provider_key) do
    provider_key(provider) == provider_key(provider_key)
  end

  defp provider_key(:openai_codex), do: "openai-codex"
  defp provider_key(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_key(provider) when is_binary(provider), do: String.replace(provider, "_", "-")
  defp provider_key(_provider), do: nil

  defp canonical_model(provider, "gpt-5") do
    case provider_key(provider) do
      "openai-codex" -> "gpt-5.5"
      _provider -> "gpt-5"
    end
  end

  defp canonical_model(_provider, model), do: model

  defp auth_context_opts(auth_opts) do
    Keyword.take(auth_opts, @auth_context_keys)
  end

  defp openai_codex do
    %{
      id: :openai_codex,
      label: "OpenAI subscription",
      model: "gpt-5.5",
      provider: :openai_codex,
      settings_provider: "openai-codex",
      auth_provider: :openai_codex,
      client: LLM.ModelClient.OpenAICodex,
      credential_resolver: &AgentApp.Auth.resolve_credential/2,
      instructions: String.trim(@default_instructions),
      text_verbosity: "low",
      thinking_level: "medium",
      thinking_levels: thinking_levels(),
      permission_mode: :trusted
    }
  end
end
