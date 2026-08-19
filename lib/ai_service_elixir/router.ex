defmodule AiServiceElixir.Router do
  @moduledoc """
  HTTP surface for the Elixir AI Service.

  Same `/run` contract as the Python service so Glific can point at either
  without a code change, and so the comparison is apples-to-apples.

  Implements FR-1 (skill as data), FR-3 (externalised transcript), FR-4 (real
  MCP reads), FR-5 (multi-step tool loop) and FR-12 (single entry point).
  """

  use Plug.Router
  require Logger

  alias AiServiceElixir.{McpClient, Skills, ThreadStore}
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
  plug(:match)
  plug(:dispatch)

  get "/health" do
    tools = McpClient.tools()

    send_json(conn, 200, %{
      status: "ok",
      mcp_configured: McpClient.configured?(),
      mcp_tools: Enum.map(tools, & &1.name),
      durable_threads: ThreadStore.configured?(),
      model: System.get_env("AI_MODEL", "claude-opus-5"),
      implements: ["FR-1", "FR-3", "FR-4", "FR-5", "FR-12"]
    })
  end

  # FR-3 proof endpoint: the transcript, recovered from the pointer alone.
  get "/threads/:thread_id" do
    send_json(conn, 200, %{thread_id: thread_id, messages: ThreadStore.raw(thread_id)})
  end

  post "/run" do
    # Tolerant destructuring: a missing key must be a 400, not a MatchError
    # 500 the way the previous version did it.
    params = conn.body_params

    case validate(params) do
      {:error, message} ->
        send_json(conn, 400, %{error: message})

      :ok ->
        send_json(conn, 200, do_run(params))
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  ## Run

  defp validate(%{"job_id" => _}), do: :ok
  defp validate(_), do: {:error, "job_id is required"}

  defp do_run(params) do
    job_id = params["job_id"]
    content = params["content"] || %{}
    thread_id = params["thread_id"] || "glific-#{AiServiceElixir.UUID.generate()}"

    {skill, routed?} = resolve_skill(params, content)

    tools = Skills.select_tools(McpClient.tools(), skill["tools"])
    context_blocks = Skills.prefetch_context(skill, content)
    system = Skills.system_prompt(skill, context_blocks)
    user = Message.new_user!(Skills.user_text(content))

    # FR-3, the hand-rolled half: LangGraph would resolve prior turns from the
    # checkpointer by thread_id. Here we load them ourselves and prepend them.
    prior = ThreadStore.load(thread_id)

    messages = [Message.new_system!(system)] ++ prior ++ [user]

    case run_chain(messages, tools) do
      {:ok, chain} ->
        answer = ThreadStore.text_of(chain.last_message.content)

        ThreadStore.append(thread_id, [user, Message.new_assistant!(%{content: answer})])

        %{
          job_id: job_id,
          thread_id: thread_id,
          skill_name: skill["name"],
          routed: routed?,
          result: %{
            skill_name: skill["name"],
            answer: answer,
            tools_called: tools_called(chain),
            context_prefetched: length(context_blocks),
            turns_in_thread: length(prior) + 2
          },
          cost_tokens: 0
        }

      {:error, reason} ->
        Logger.error("run failed: #{inspect(reason)}")

        %{
          job_id: job_id,
          thread_id: thread_id,
          skill_name: skill["name"],
          routed: routed?,
          result: %{error: inspect(reason)},
          cost_tokens: 0
        }
    end
  end

  defp run_chain(messages, tools) do
    %{llm: Skills.anthropic()}
    |> LLMChain.new!()
    |> LLMChain.add_tools(tools)
    |> LLMChain.add_messages(messages)
    |> LLMChain.run(mode: :while_needs_response)
  rescue
    error -> {:error, Exception.message(error)}
  end

  # FR-12 -- no skill supplied means the person just typed into the chat box.
  defp resolve_skill(%{"skill" => skill}, _content) when is_map(skill), do: {skill, false}

  defp resolve_skill(params, content) do
    menu = params["skills_menu"] || []
    text = Skills.user_text(content)

    case Skills.route(text, menu) do
      {nil, _why} -> {%{"name" => nil}, true}
      {name, _why} -> {Enum.find(menu, &(&1["name"] == name)), true}
    end
  end

  defp tools_called(chain) do
    (chain.exchanged_messages || [])
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(fn m -> Enum.map(m.tool_results || [], & &1.name) end)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end

