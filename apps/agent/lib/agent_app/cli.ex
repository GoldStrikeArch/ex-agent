defmodule AgentApp.CLI do
  @moduledoc """
  Command-line entrypoint for the runnable agent application.
  """

  @doc """
  Starts the interactive terminal UI or runs utility commands.
  """
  @spec main([String.t()]) :: :ok
  def main(args) do
    {:ok, _apps} = Application.ensure_all_started(:agent)

    case args do
      ["--login", "openai_codex"] ->
        login_openai_codex()

      ["--replay", path] ->
        Tui.Replay.render_file(path)

      _args ->
        {session_opts, prompt_args} = session_opts(args)
        initial_prompt = prompt_args |> Enum.join(" ") |> String.trim()
        run_terminal_app(session_opts, initial_prompt)
    end
  end

  defp login_openai_codex do
    result =
      AgentApp.Auth.login(:openai_codex,
        callbacks: %{
          on_auth: fn info ->
            IO.puts("Open this URL to authenticate:")
            IO.puts(info.url)
            IO.puts(info.instructions)
          end,
          on_prompt: fn prompt ->
            prompt.message
            |> IO.gets()
            |> case do
              :eof -> {:error, :eof}
              {:error, reason} -> {:error, reason}
              input -> {:ok, String.trim(input)}
            end
          end
        }
      )

    case result do
      {:ok, credential} ->
        IO.puts("Stored OpenAI Codex credentials for account #{credential.account_id}.")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Login failed: #{inspect(reason)}")
        :ok
    end
  end

  defp session_opts(args) do
    {flags, prompt_args} = parse_flags(args, %{}, [])

    if flags[:model] do
      opts = [
        model_client: LLM.ModelClient.OpenAICodex,
        model_opts:
          [
            model: flags[:model],
            provider: flags[:provider],
            auth_provider: flags[:auth_provider],
            base_url: flags[:base_url],
            credential_resolver: &AgentApp.Auth.resolve_credential/2
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end),
        permission_mode: :trusted
      ]

      {opts, prompt_args}
    else
      {[], prompt_args}
    end
  end

  defp parse_flags([], flags, prompt_args), do: {flags, Enum.reverse(prompt_args)}

  defp parse_flags(["--model", model | rest], flags, prompt_args),
    do: parse_flags(rest, Map.put(flags, :model, model), prompt_args)

  defp parse_flags(["--provider", provider | rest], flags, prompt_args) do
    parse_flags(rest, Map.put(flags, :provider, provider_atom(provider)), prompt_args)
  end

  defp parse_flags(["--auth-provider", "openai_codex" | rest], flags, prompt_args) do
    parse_flags(rest, Map.put(flags, :auth_provider, :openai_codex), prompt_args)
  end

  defp parse_flags(["--base-url", base_url | rest], flags, prompt_args) do
    parse_flags(rest, Map.put(flags, :base_url, base_url), prompt_args)
  end

  defp parse_flags([arg | rest], flags, prompt_args),
    do: parse_flags(rest, flags, [arg | prompt_args])

  defp provider_atom("openai_codex"), do: :openai_codex
  defp provider_atom("openai"), do: :openai
  defp provider_atom(provider), do: provider

  defp run_terminal_app(session_opts, initial_prompt) do
    case AgentApp.Interactive.run(
           session_opts: session_opts,
           initial_prompt: initial_prompt
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "TUI failed: #{inspect(reason)}")
        :ok
    end
  end
end
