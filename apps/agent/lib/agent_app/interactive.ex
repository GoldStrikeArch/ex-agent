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

    session_opts = default_unconfigured_session_opts(session_opts)

    session_opts
    |> start_session_resources()
    |> wait_with_session_resources(runtime, bridge, initial_prompt, auth_opts)
  end

  defp start_session_resources(session_opts) do
    with {:ok, session} <- Core.start_session(session_opts) do
      start_model_state_resource(session, configured_session?(session_opts))
    end
  end

  defp start_model_state_resource(session, configured?) do
    case Agent.start_link(fn -> %{configured?: configured?} end) do
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
  def handle_command(:model, _context, runtime, session, model_state, auth_opts) do
    setup_model(runtime, session, model_state, auth_opts)
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
    option = ModelCatalog.default()

    with {:ok, _credential} <- resolve_or_login(option, runtime, auth_opts) do
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
      Agent.update(model_state, fn state -> %{state | configured?: true} end)
      persist_model_selection(option, runtime, auth_opts)
      TerminalApp.append_notice(runtime, "model configured: #{option.label} (#{option.model})")
    end
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

  defp model_setup_failed_notice(:manual_oauth_paste_not_supported_in_tui) do
    "browser callback login failed; run `agent --login openai_codex` and then /model"
  end

  defp model_setup_failed_notice(reason) do
    "model setup failed: #{inspect(reason)}"
  end

  defp model_configured?(model_state) do
    Agent.get(model_state, & &1.configured?)
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
