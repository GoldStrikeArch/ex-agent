defmodule AgentApp.Interactive do
  @moduledoc """
  Owns the interactive terminal mode lifecycle.

  This module composes `Core` sessions with `Tui` rendering. The UI
  process is started before the core session so startup events are not missed.
  """

  alias AgentApp.EventBridge
  alias AgentApp.ModelDefaults
  alias AgentApp.ModelCatalog
  alias Tui.TerminalApp

  @model_not_configured_notice "please set the model with /model to use the agent"
  @model_command_usage "usage: /model [default|minimal|low|medium|high]"

  @doc """
  Runs an interactive terminal session.

  Options:

    * `:session_opts` - options passed to `Core.start_session/1`.
    * `:initial_prompt` - optional prompt submitted after session startup.
    * `:test_mode` - optional `{width, height}` headless TUI for tests.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started(:agent)

    {session_opts, tui_opts} = Keyword.pop(opts, :session_opts, [])
    auth_opts = Keyword.get(opts, :auth_opts, [])

    case TerminalApp.start_link(tui_opts) do
      {:ok, runtime} ->
        start_bridge_and_session(
          runtime,
          session_opts,
          Keyword.get(tui_opts, :initial_prompt, ""),
          auth_opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_bridge_and_session(runtime, session_opts, initial_prompt, auth_opts) do
    case EventBridge.start_link(runtime: runtime) do
      {:ok, bridge} ->
        start_session_and_wait(runtime, bridge, session_opts, initial_prompt, auth_opts)

      {:error, reason} ->
        TerminalApp.shutdown(runtime)
        {:error, reason}
    end
  end

  defp start_session_and_wait(runtime, bridge, session_opts, initial_prompt, auth_opts) do
    {session_opts, restore_notice} = ModelDefaults.apply_to_session_opts(session_opts, auth_opts)
    maybe_append_notice(runtime, restore_notice)

    session_opts =
      session_opts
      |> default_unconfigured_session_opts()
      |> maybe_enable_structural()

    maybe_index_workspace(session_opts)

    session_opts
    |> start_session_resources()
    |> wait_with_session_resources(runtime, bridge, initial_prompt, auth_opts)
  end

  # Routes the structural tools to the Tree-sitter backend when its parser is
  # loaded; otherwise the core default (`Unavailable`) keeps them degrading to
  # `backend_unavailable`.
  defp maybe_enable_structural(session_opts) do
    if Structural.Backend.available?() do
      Keyword.put_new(session_opts, :structural_backend, Structural.Backend)
    else
      session_opts
    end
  end

  # Builds the structural index for the workspace in the background so the first
  # structural query has data. Gated by `:index_workspace` (the CLI sets it) so
  # tests and embedders do not index implicitly.
  defp maybe_index_workspace(session_opts) do
    if Keyword.get(session_opts, :index_workspace, false) and Structural.Backend.available?() do
      root = Keyword.get(session_opts, :workspace_root) || File.cwd!()
      Task.start(fn -> Structural.Index.index_path(Structural.Index, root) end)
    end

    :ok
  end

  defp start_session_resources(session_opts) do
    with {:ok, session} <- Core.start_session(session_opts) do
      start_model_state_resource(session, session_opts, configured_session?(session_opts))
    end
  end

  defp start_model_state_resource(session, session_opts, configured?) do
    model = model_status_from_session_opts(session_opts)

    case Agent.start_link(fn -> %{configured?: configured?, model: model} end) do
      {:ok, model_state} ->
        {:ok, %{session: session, model_state: model_state}}

      {:error, reason} ->
        stop_session(session)
        {:error, reason}
    end
  end

  defp wait_with_session_resources(
         {:ok, resources},
         runtime,
         bridge,
         initial_prompt,
         auth_opts
       ) do
    try do
      install_session_callbacks(runtime, resources, auth_opts)
      maybe_submit_initial_prompt(runtime, initial_prompt)
      TerminalApp.wait(runtime)
    after
      stop_session_resources(resources)
      stop_bridge(bridge)
    end
  end

  defp wait_with_session_resources({:error, reason}, runtime, bridge, _initial_prompt, _auth_opts) do
    TerminalApp.shutdown(runtime)
    stop_bridge(bridge)
    {:error, reason}
  end

  defp install_session_callbacks(
         runtime,
         %{session: session, model_state: model_state},
         auth_opts
       ) do
    maybe_send_model_status(runtime, model_status(model_state))
    TerminalApp.set_submit_prompt(runtime, &submit_prompt(runtime, session, model_state, &1))

    TerminalApp.set_command_handler(
      runtime,
      &handle_command(&1, &2, runtime, session, model_state, auth_opts)
    )
  end

  defp stop_session_resources(%{session: session, model_state: model_state}) do
    stop_model_state(model_state)
    stop_session(session)
  end

  defp maybe_submit_initial_prompt(_runtime, ""), do: :ok
  defp maybe_submit_initial_prompt(_runtime, nil), do: :ok

  defp maybe_submit_initial_prompt(runtime, prompt) when is_binary(prompt) do
    TerminalApp.submit_initial(runtime, prompt)
  end

  defp maybe_append_notice(_runtime, nil), do: :ok

  defp maybe_append_notice(runtime, notice) when is_binary(notice) do
    TerminalApp.append_notice(runtime, notice)
  end

  @doc """
  Handles slash commands delegated from the terminal UI.

  This is the command-handler callback installed by `run/1`. Unknown commands
  return structured errors so the TUI can render them as command failures.
  """
  @spec handle_command(
          atom(),
          Tui.TerminalApp.command_context(),
          GenServer.server(),
          pid(),
          pid(),
          keyword()
        ) :: :ok | {:error, term()}
  def handle_command(:model, context, runtime, session, model_state, auth_opts) do
    with {:ok, model_opts} <- model_command_opts(context) do
      setup_model(runtime, session, model_state, auth_opts, model_opts)
    end
  end

  def handle_command(command_id, _context, _runtime, _session, _model_state, _auth_opts) do
    {:error, {:unknown_command, command_id}}
  end

  @doc """
  Resolves credentials and configures the current session for the catalog model.

  The selected model is persisted as the user default. The function appends auth
  instructions, setup success, persistence warnings, or setup failure notices to
  the terminal runtime as side effects.
  """
  @spec setup_model(GenServer.server(), pid(), pid(), keyword()) :: :ok | {:error, term()}
  def setup_model(runtime, session, model_state, auth_opts) do
    setup_model(runtime, session, model_state, auth_opts, [])
  end

  @doc """
  Resolves credentials and configures the current session with command options.
  """
  @spec setup_model(GenServer.server(), pid(), pid(), keyword(), keyword()) ::
          :ok | {:error, term()}
  def setup_model(runtime, session, model_state, auth_opts, model_opts) do
    with {:ok, option} <- selected_model_option(model_opts),
         {:ok, _credential} <- resolve_or_login(option, runtime, auth_opts) do
      configure_model(option, runtime, session, model_state, auth_opts)
    else
      {:error, reason} = error ->
        TerminalApp.append_notice(runtime, model_setup_failed_notice(reason))
        error
    end
  end

  @doc """
  Submits a prompt to the core session when a model is configured.

  If the session is still unconfigured, no model call is made and the TUI gets a
  setup notice instead.
  """
  @spec submit_prompt(GenServer.server(), pid(), pid(), String.t()) ::
          :ok | {:ok, map()} | {:error, term()}
  def submit_prompt(runtime, session, model_state, prompt) do
    model_state
    |> model_configured?()
    |> submit_prompt_with_model(runtime, session, prompt)
  end

  defp submit_prompt_with_model(true, _runtime, session, prompt) do
    Core.send_message(session, prompt)
  end

  defp submit_prompt_with_model(false, runtime, _session, _prompt) do
    TerminalApp.append_notice(runtime, @model_not_configured_notice)
    :ok
  end

  defp resolve_or_login(option, runtime, auth_opts) do
    resolver = Keyword.get(auth_opts, :credential_resolver, &AgentApp.Auth.resolve_credential/2)

    case resolver.(option.auth_provider, auth_opts) do
      {:ok, credential} -> {:ok, credential}
      {:error, _reason} -> login(option, runtime, auth_opts)
    end
  end

  defp login(option, runtime, auth_opts) do
    login = Keyword.get(auth_opts, :login, &AgentApp.Auth.login/2)
    login.(option.auth_provider, Keyword.put(auth_opts, :callbacks, login_callbacks(runtime)))
  end

  defp login_callbacks(runtime) do
    %{
      on_auth: fn info ->
        TerminalApp.append_notice(
          runtime,
          "Open this URL to authenticate:\n#{info.url}\n#{info.instructions}"
        )
      end,
      on_prompt: fn _prompt ->
        {:error, :manual_oauth_paste_not_supported_in_tui}
      end
    }
  end

  defp configure_model(option, runtime, session, model_state, auth_opts) do
    with :ok <- Core.configure_model(session, ModelCatalog.core_opts(option, auth_opts)) do
      model = ModelCatalog.status_info(option)

      Agent.update(model_state, fn state ->
        Map.merge(state, %{configured?: true, model: model})
      end)

      TerminalApp.send_event(runtime, {:model_configured, model})
      persist_model_selection(option, runtime, auth_opts)
      TerminalApp.append_notice(runtime, model_configured_notice(option))
    end
  end

  defp selected_model_option(opts) do
    option = ModelCatalog.default()
    level = Keyword.get(opts, :thinking_level, option.thinking_level)
    ModelCatalog.with_thinking_level(option, level)
  end

  defp persist_model_selection(option, runtime, auth_opts) do
    case ModelDefaults.persist(option, auth_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        TerminalApp.append_notice(
          runtime,
          "model configured for this session, but saving preference failed: #{inspect(reason)}"
        )
    end
  end

  defp model_configured_notice(option) do
    thinking = LLM.Thinking.label(option.thinking_level)
    "model configured: #{option.label} (#{option.model}, thinking #{thinking})"
  end

  defp model_setup_failed_notice(:manual_oauth_paste_not_supported_in_tui) do
    "browser callback login failed; run `agent --login openai_codex` and then /model"
  end

  defp model_setup_failed_notice({:invalid_model_command, usage}) do
    usage
  end

  defp model_setup_failed_notice(reason) do
    "model setup failed: #{inspect(reason)}"
  end

  defp model_configured?(model_state) do
    Agent.get(model_state, &Map.get(&1, :configured?, false))
  end

  defp model_status(model_state) do
    Agent.get(model_state, &Map.get(&1, :model))
  end

  defp maybe_send_model_status(_runtime, nil), do: :ok

  defp maybe_send_model_status(runtime, model) do
    TerminalApp.send_event(runtime, {:model_configured, model})
  end

  defp model_command_opts(%{prompt: prompt}) when is_binary(prompt) do
    prompt
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.drop(1)
    |> parse_model_args()
  end

  defp model_command_opts(_context), do: {:ok, []}

  defp parse_model_args([]), do: {:ok, []}
  defp parse_model_args([level]), do: thinking_option(level)
  defp parse_model_args(["thinking", level]), do: thinking_option(level)
  defp parse_model_args(["--thinking", level]), do: thinking_option(level)
  defp parse_model_args(["--reasoning-effort", level]), do: thinking_option(level)
  defp parse_model_args(["--thinking=" <> level]), do: thinking_option(level)
  defp parse_model_args(["--reasoning-effort=" <> level]), do: thinking_option(level)
  defp parse_model_args(_args), do: {:error, {:invalid_model_command, @model_command_usage}}

  defp thinking_option(level) do
    case LLM.Thinking.normalize(level) do
      {:ok, normalized} -> {:ok, [thinking_level: normalized]}
      {:error, _reason} -> {:error, {:invalid_model_command, @model_command_usage}}
    end
  end

  defp model_status_from_session_opts(session_opts) do
    model_opts = Keyword.get(session_opts, :model_opts, [])

    case Keyword.get(model_opts, :model) do
      model when is_binary(model) and model != "" ->
        %{
          label: "configured model",
          provider: Keyword.get(model_opts, :provider),
          model: model,
          thinking_level: status_thinking_level(model_opts)
        }

      _model ->
        nil
    end
  end

  defp status_thinking_level(model_opts) do
    model_opts
    |> Keyword.get(:reasoning_effort, Keyword.get(model_opts, :thinking_level))
    |> LLM.Thinking.normalize()
    |> case do
      {:ok, level} -> level
      {:error, _reason} -> nil
    end
  end

  defp configured_session?(session_opts) do
    Keyword.has_key?(session_opts, :model_client) and
      Keyword.get(session_opts, :model_client) != Core.ModelClient.Unconfigured
  end

  defp default_unconfigured_session_opts(session_opts) do
    session_opts
    |> configured_session?()
    |> default_unconfigured_session_opts(session_opts)
  end

  defp default_unconfigured_session_opts(true, session_opts), do: session_opts

  defp default_unconfigured_session_opts(false, session_opts) do
    Keyword.put_new(session_opts, :model_client, Core.ModelClient.Unconfigured)
  end

  defp stop_session(session) do
    Core.stop_session(session)
  end

  defp stop_model_state(model_state) do
    stop_if_alive(model_state, &Agent.stop/1)
  end

  defp stop_bridge(bridge) do
    stop_if_alive(bridge, &GenServer.stop/1)
  end

  defp stop_if_alive(pid, stop) when is_pid(pid) and is_function(stop, 1) do
    case Process.alive?(pid) do
      true -> stop.(pid)
      false -> :ok
    end
  end
end
