defmodule AgentApp.InteractiveTest do
  use ExUnit.Case, async: false

  alias AgentApp.Auth.Storage
  alias AgentApp.Interactive
  alias AgentApp.Settings
  alias LLM.Auth.Credential
  alias Tui.TerminalApp

  test "unconfigured prompt appends friendly model setup notice" do
    runtime = start_runtime(60, 12)
    {:ok, session} = Core.start_session(model_client: Core.ModelClient.Unconfigured)
    {:ok, model_state} = Agent.start_link(fn -> %{configured?: false} end)

    on_exit(fn ->
      stop_if_alive(model_state, &Agent.stop/1)
      stop_if_alive(session, &Core.stop_session/1)
      stop_if_alive(runtime, &TerminalApp.shutdown/1)
    end)

    assert :ok = Interactive.submit_prompt(runtime, session, model_state, "hello")

    assert_eventually(fn ->
      runtime
      |> transcript_lines()
      |> Enum.member?("please set the model with /model to use the agent")
    end)
  end

  test "model command with stored credentials configures OpenAI subscription model" do
    agent_dir = tmp_dir()
    credential = credential()
    assert :ok = Storage.write(:openai_codex, credential, agent_dir: agent_dir)

    runtime = start_runtime(80, 12)
    {:ok, session} = Core.start_session(model_client: Core.ModelClient.Unconfigured)
    {:ok, model_state} = Agent.start_link(fn -> %{configured?: false} end)

    on_exit(fn ->
      stop_if_alive(model_state, &Agent.stop/1)
      stop_if_alive(session, &Core.stop_session/1)
      stop_if_alive(runtime, &TerminalApp.shutdown/1)
    end)

    assert :ok = Interactive.setup_model(runtime, session, model_state, agent_dir: agent_dir)

    state = :sys.get_state(session)
    assert state.model_client == LLM.ModelClient.OpenAICodex
    assert state.model_opts[:model] == "gpt-5.5"
    assert state.model_opts[:provider] == :openai_codex
    assert state.model_opts[:auth_provider] == :openai_codex
    assert state.model_opts[:reasoning_effort] == "medium"
    assert is_function(state.model_opts[:credential_resolver], 2)
    assert state.model_opts[:agent_dir] == agent_dir
    assert is_binary(state.model_opts[:instructions])
    assert state.permission_mode == :trusted
    assert Agent.get(model_state, & &1.configured?)
    assert Agent.get(model_state, & &1.model.thinking_level) == "medium"

    assert {:ok, %{provider: "openai-codex", model: "gpt-5.5", thinking_level: "medium"}} =
             Settings.default_model(agent_dir: agent_dir)

    assert_eventually(fn ->
      %{user_state: ui_state} = :sys.get_state(runtime)
      ui_state.status.model && ui_state.status.model.thinking_level == "medium"
    end)
  end

  test "model command can choose a thinking level" do
    agent_dir = tmp_dir()
    credential = credential()
    assert :ok = Storage.write(:openai_codex, credential, agent_dir: agent_dir)

    runtime = start_runtime(80, 12)
    {:ok, session} = Core.start_session(model_client: Core.ModelClient.Unconfigured)
    {:ok, model_state} = Agent.start_link(fn -> %{configured?: false} end)

    on_exit(fn ->
      stop_if_alive(model_state, &Agent.stop/1)
      stop_if_alive(session, &Core.stop_session/1)
      stop_if_alive(runtime, &TerminalApp.shutdown/1)
    end)

    assert :ok =
             Interactive.handle_command(
               :model,
               %{prompt: "/model high"},
               runtime,
               session,
               model_state,
               agent_dir: agent_dir
             )

    state = :sys.get_state(session)
    assert state.model_opts[:reasoning_effort] == "high"

    assert {:ok, %{thinking_level: "high"}} = Settings.default_model(agent_dir: agent_dir)

    assert_eventually(fn ->
      %{user_state: ui_state} = :sys.get_state(runtime)
      ui_state.status.model && ui_state.status.model.thinking_level == "high"
    end)
  end

  test "model command logs auth instructions when credentials are missing" do
    agent_dir = tmp_dir()
    parent = self()

    resolver = fn :openai_codex, _opts ->
      {:error, {:missing_credentials, :openai_codex}}
    end

    login = fn :openai_codex, opts ->
      send(parent, {:login_started, opts[:callbacks]})
      opts[:callbacks].on_auth.(%{url: "https://auth.example.test", instructions: "finish login"})
      {:ok, credential()}
    end

    runtime = start_runtime(80, 12)
    {:ok, session} = Core.start_session(model_client: Core.ModelClient.Unconfigured)
    {:ok, model_state} = Agent.start_link(fn -> %{configured?: false} end)

    on_exit(fn ->
      stop_if_alive(model_state, &Agent.stop/1)
      stop_if_alive(session, &Core.stop_session/1)
      stop_if_alive(runtime, &TerminalApp.shutdown/1)
    end)

    assert :ok =
             Interactive.setup_model(runtime, session, model_state,
               agent_dir: agent_dir,
               credential_resolver: resolver,
               login: login
             )

    assert_receive {:login_started, %{on_auth: on_auth, on_prompt: on_prompt}}
    assert is_function(on_auth, 1)
    assert is_function(on_prompt, 1)

    assert_eventually(fn ->
      lines = transcript_lines(runtime)
      "https://auth.example.test" in lines and "finish login" in lines
    end)
  end

  defp credential do
    %Credential{
      access: jwt("acct_1"),
      refresh: "refresh-token",
      expires_at: System.system_time(:millisecond) + 120_000,
      account_id: "acct_1"
    }
  end

  defp jwt(account_id) do
    header = %{"alg" => "none"} |> JSON.encode!() |> Base.url_encode64(padding: false)

    payload =
      %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}}
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    header <> "." <> payload <> ".sig"
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "agent-interactive-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp transcript_lines(runtime) do
    %{user_state: state} = :sys.get_state(runtime)
    Tui.TerminalApp.Transcript.visible_lines(state.transcript, 120, 20)
  end

  defp assert_eventually(fun) do
    assert_eventually(fun, 20)
  end

  defp assert_eventually(fun, attempts_left) when attempts_left > 1 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts_left - 1)
    end
  end

  defp assert_eventually(fun, 1), do: assert(fun.())

  defp start_runtime(width, height) do
    {:ok, runtime} = TerminalApp.start_link(test_mode: {width, height})
    Process.unlink(runtime)
    runtime
  end

  defp stop_if_alive(pid, stop) do
    if Process.alive?(pid), do: stop.(pid)
  end
end
