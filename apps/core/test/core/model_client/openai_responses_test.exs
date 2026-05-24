defmodule Core.ModelClient.OpenAIResponsesTest do
  use ExUnit.Case, async: false

  alias Core.ModelClient.OpenAIResponses

  test "builds a Responses request and streams text deltas" do
    parent = self()

    transport = fn request, event_sink ->
      send(parent, {:request, request})

      OpenAIResponses.from_events(
        [
          %{"type" => "response.output_text.delta", "delta" => "hello"},
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ],
        event_sink
      )
    end

    assert {:ok, "hello"} =
             OpenAIResponses.stream_chat(
               [%{role: :user, content: "say hello"}],
               [%{name: "read_file", description: "Read", schema: %{type: "object"}}],
               [model: "gpt-test", api_key: "sk-test", transport: transport],
               fn _delta -> :ok end
             )

    assert_receive {:request, request}
    assert request.url == "https://api.openai.com/v1/responses"
    assert {"authorization", "Bearer sk-test"} in request.headers

    assert %{
             model: "gpt-test",
             stream: true,
             store: false,
             input: [%{role: "user", content: "say hello"}],
             tools: [
               %{
                 type: "function",
                 name: "read_file",
                 description: "Read",
                 parameters: %{type: "object"},
                 strict: false
               }
             ]
           } = request.body
  end

  test "maps streamed function calls into internal tool calls" do
    assert {:ok,
            %{
              content: "checking",
              tool_calls: [
                %{
                  id: "call_1",
                  provider_id: "fc_1",
                  name: "read_file",
                  args: %{"path" => "mix.exs"}
                }
              ]
            }} =
             OpenAIResponses.from_events(
               [
                 %{"type" => "response.output_text.delta", "delta" => "checking"},
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
                 }
               ],
               fn _delta -> :ok end
             )
  end

  test "converts tool result transcript messages to function_call_output input" do
    assert {:ok, request} =
             OpenAIResponses.build_request(
               [
                 %{role: :user, content: "read"},
                 %{
                   role: :assistant,
                   content: "",
                   tool_calls: [
                     %{id: "call_1", provider_id: "fc_1", name: "read_file", args: %{}}
                   ]
                 },
                 %{
                   role: :tool,
                   tool_call_id: "call_1",
                   name: "read_file",
                   status: :ok,
                   content: "file contents",
                   summary: "read file"
                 }
               ],
               [],
               model: "gpt-test",
               api_key: "sk-test"
             )

    assert [
             %{role: "user", content: "read"},
             %{type: "function_call", id: "fc_1", call_id: "call_1", name: "read_file"},
             %{type: "function_call_output", call_id: "call_1", output: "file contents"}
           ] = request.body.input
  end

  test "runs the session tool loop with a fake Responses transport" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "agent-core-openai-session-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "mix.exs"), "defmodule RealProviderSample do\nend\n")
    on_exit(fn -> File.rm_rf(workspace) end)

    transport = fn request, event_sink ->
      if Enum.any?(request.body.input, &match?(%{type: "function_call_output"}, &1)) do
        OpenAIResponses.from_events(
          [%{"type" => "response.output_text.delta", "delta" => "done"}],
          event_sink
        )
      else
        OpenAIResponses.from_events(
          [
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
            }
          ],
          event_sink
        )
      end
    end

    assert {:ok, session} =
             Core.start_session(
               workspace_root: workspace,
               model_client: OpenAIResponses,
               model_opts: [model: "gpt-test", api_key: "sk-test", transport: transport]
             )

    assert {:ok, %{content: "done"}} = Core.send_message(session, "inspect project")
    assert {:ok, messages} = Core.messages(session)

    assert [
             %{role: :user},
             %{role: :assistant, tool_calls: [%{id: "call_1", name: "read_file"}]},
             %{
               role: :tool,
               tool_call_id: "call_1",
               content: "defmodule RealProviderSample do\nend\n"
             },
             %{role: :assistant, content: "done"}
           ] = messages

    assert :ok = Core.stop_session(session)
  end
end
