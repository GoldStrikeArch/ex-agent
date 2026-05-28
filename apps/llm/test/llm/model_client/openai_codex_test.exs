defmodule LLM.ModelClient.OpenAICodexTest do
  use ExUnit.Case, async: false

  alias LLM.Auth.Credential
  alias LLM.ModelClient.OpenAICodex

  test "builds Codex SSE and WebSocket requests from an injected credential" do
    assert {:ok, request} =
             OpenAICodex.build_request(
               [%{role: :user, content: "hello"}],
               [%{name: "shell", description: "Run shell", schema: %{type: "object"}}],
               model: "gpt-test",
               credential: credential(),
               instructions: "agent rules",
               reasoning_effort: "high",
               session_id: "session-1"
             )

    assert request.url == "https://chatgpt.com/backend-api/codex/responses"
    assert request.websocket_url == "wss://chatgpt.com/backend-api/codex/responses"

    assert {"authorization", "Bearer access-token"} in request.sse_headers
    assert {"chatgpt-account-id", "acct_1"} in request.sse_headers
    assert {"originator", "ex-agent"} in request.sse_headers
    assert {"user-agent", "ex (elixir-agent)"} in request.sse_headers
    assert {"openai-beta", "responses=experimental"} in request.sse_headers
    assert {"accept", "text/event-stream"} in request.sse_headers
    assert {"content-type", "application/json"} in request.sse_headers
    assert {"session_id", "session-1"} in request.sse_headers
    assert {"x-client-request-id", "session-1"} in request.sse_headers

    assert {"openai-beta", "responses_websockets=2026-02-06"} in request.websocket_headers
    refute Enum.any?(request.websocket_headers, fn {key, _value} -> key == "accept" end)
    refute Enum.any?(request.websocket_headers, fn {key, _value} -> key == "content-type" end)

    assert %{
             input: [%{role: "user", content: [%{type: "input_text", text: "hello"}]}],
             instructions: "agent rules",
             tools: [
               %{
                 type: "function",
                 name: "shell",
                 description: "Run shell",
                 parameters: %{type: "object"},
                 strict: nil
               }
             ],
             reasoning: %{effort: "high"},
             text: %{verbosity: "low"},
             include: ["reasoning.encrypted_content"],
             tool_choice: "auto",
             parallel_tool_calls: true,
             prompt_cache_key: "session-1"
           } = request.body
  end

  test "rejects invalid thinking levels before resolving transport" do
    assert {:error, {:invalid_thinking_level, "huge", _levels}} =
             OpenAICodex.build_request(
               [%{role: :user, content: "hello"}],
               [],
               model: "gpt-test",
               credential: credential(),
               reasoning_effort: "huge"
             )
  end

  test "websocket transport sends response.create and streams text deltas" do
    parent = self()

    websocket_transport = fn request, state, callbacks ->
      send(parent, {:websocket_request, request})

      {:cont, state} =
        callbacks[:on_text].(
          JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "hello"}),
          state
        )

      {:halt, state, metadata} =
        callbacks[:on_text].(
          JSON.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_1",
              "status" => "completed",
              "output" => [
                %{
                  "type" => "message",
                  "id" => "msg_provider",
                  "role" => "assistant",
                  "status" => "completed",
                  "content" => [
                    %{"type" => "output_text", "text" => "hello", "annotations" => []}
                  ]
                }
              ]
            }
          }),
          state
        )

      send(parent, {:metadata, metadata})
      callbacks[:on_success].(state, metadata)
    end

    assert {:ok, "hello"} =
             OpenAICodex.stream_chat(
               [%{role: :user, content: "say hello"}],
               [],
               [
                 model: "gpt-test",
                 credential: credential(),
                 transport: :websocket,
                 websocket_transport: websocket_transport
               ],
               fn _delta -> :ok end
             )

    assert_receive {:websocket_request, request}

    assert %{"type" => "response.create", "input" => [%{"role" => "user"}]} =
             JSON.decode!(request.text)

    assert request.url == "wss://chatgpt.com/backend-api/codex/responses"

    assert_receive {:metadata,
                    %{
                      last_response_id: "resp_1",
                      response_input: [%{"type" => "message"}]
                    }}
  end

  test "websocket transport streams function calls through the response reducer" do
    websocket_transport = fn _request, state, callbacks ->
      events = [
        %{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "call_1",
            "name" => "read_file",
            "arguments" => ""
          }
        },
        %{
          "type" => "response.function_call_arguments.delta",
          "output_index" => 0,
          "delta" => ~S({"path":"mix.exs"})
        },
        %{
          "type" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "call_1",
            "name" => "read_file",
            "arguments" => ~S({"path":"mix.exs"})
          }
        },
        %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_1", "status" => "completed"}
        }
      ]

      {state, metadata} =
        Enum.reduce_while(events, {state, nil}, fn event, {next_state, _metadata} ->
          case callbacks[:on_text].(JSON.encode!(event), next_state) do
            {:cont, next_state} -> {:cont, {next_state, nil}}
            {:halt, next_state, metadata} -> {:halt, {next_state, metadata}}
          end
        end)

      callbacks[:on_success].(state, metadata)
    end

    assert {:ok,
            %{
              content: "",
              tool_calls: [%{id: "call_1", provider_id: "fc_1", name: "read_file"}]
            }} =
             OpenAICodex.stream_chat(
               [%{role: :user, content: "read"}],
               [],
               [
                 model: "gpt-test",
                 credential: credential(),
                 transport: :websocket,
                 websocket_transport: websocket_transport
               ],
               fn _delta -> :ok end
             )
  end

  test "auto falls back to SSE only when websocket fails before the first event" do
    parent = self()

    websocket_transport = fn _request, _state, _callbacks ->
      {:error, {:network_websocket_failed, :before_start, :econnrefused}}
    end

    sse_transport = fn request, event_sink ->
      send(parent, {:sse_request, request})

      OpenAICodex.from_events(
        [%{"type" => "response.output_text.delta", "delta" => "fallback"}],
        event_sink
      )
    end

    assert {:ok, "fallback"} =
             OpenAICodex.stream_chat(
               [%{role: :user, content: "hello"}],
               [],
               [
                 model: "gpt-test",
                 credential: credential(),
                 websocket_transport: websocket_transport,
                 sse_transport: sse_transport
               ],
               fn _delta -> :ok end
             )

    assert_receive {:sse_request, %{url: "https://chatgpt.com/backend-api/codex/responses"}}
  end

  test "auto does not fall back to SSE after websocket has yielded an event" do
    parent = self()

    websocket_transport = fn _request, _state, _callbacks ->
      {:error, {:network_websocket_failed, :after_start, :closed}}
    end

    sse_transport = fn _request, _event_sink ->
      send(parent, :unexpected_sse)
      {:ok, "should not happen"}
    end

    assert {:error, {:openai_codex_websocket_failed, :after_start, :closed}} =
             OpenAICodex.stream_chat(
               [%{role: :user, content: "hello"}],
               [],
               [
                 model: "gpt-test",
                 credential: credential(),
                 websocket_transport: websocket_transport,
                 sse_transport: sse_transport
               ],
               fn _delta -> :ok end
             )

    refute_receive :unexpected_sse
  end

  test "transport sse skips websocket and preserves SSE behavior" do
    parent = self()

    sse_transport = fn request, event_sink ->
      send(parent, {:sse_request, request})

      OpenAICodex.from_events(
        [%{"type" => "response.output_text.delta", "delta" => "sse"}],
        event_sink
      )
    end

    assert {:ok, "sse"} =
             OpenAICodex.stream_chat(
               [%{role: :user, content: "hello"}],
               [],
               [
                 model: "gpt-test",
                 credential: credential(),
                 transport: :sse,
                 sse_transport: sse_transport
               ],
               fn _delta -> :ok end
             )

    assert_receive {:sse_request, request}
    assert {"accept", "text/event-stream"} in request.headers
  end

  test "cached continuation sends previous_response_id and input delta on matching follow-up" do
    first_body = %{
      model: "gpt-test",
      stream: true,
      input: [%{role: "user", content: [%{type: "input_text", text: "hello"}]}]
    }

    response_input = [
      %{
        "type" => "message",
        "id" => "provider_msg_1",
        "role" => "assistant",
        "status" => "completed",
        "content" => [%{"type" => "output_text", "text" => "hi", "annotations" => []}]
      }
    ]

    next_user = %{role: "user", content: [%{type: "input_text", text: "again"}]}

    next_body = %{
      first_body
      | input:
          first_body.input ++
            [
              %{
                type: "message",
                id: "msg_1",
                role: "assistant",
                status: "completed",
                content: [%{type: "output_text", text: "hi", annotations: []}]
              },
              next_user
            ]
    }

    continuation = %{
      last_request_body: first_body,
      last_response_id: "resp_1",
      response_input: response_input
    }

    assert {:delta, delta_body} = OpenAICodex.prepare_websocket_body(next_body, continuation)
    assert delta_body.previous_response_id == "resp_1"
    assert delta_body.input == [next_user]
  end

  test "cached continuation mismatch sends a full body" do
    first_body = %{model: "gpt-test", input: [%{role: "user", content: []}], instructions: "one"}
    next_body = %{first_body | instructions: "two"}

    continuation = %{
      last_request_body: first_body,
      last_response_id: "resp_1",
      response_input: []
    }

    assert {:mismatch, ^next_body} = OpenAICodex.prepare_websocket_body(next_body, continuation)
  end

  defp credential do
    %Credential{
      access: "access-token",
      refresh: "refresh-token",
      expires_at: System.system_time(:millisecond) + 60_000,
      account_id: "acct_1"
    }
  end
end
