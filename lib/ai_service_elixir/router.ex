defmodule AiServiceElixir.Router do
  @moduledoc """
  AI Service — pure-Elixir sandbox variant (elixir-langchain).

  Step 3 scope: real LLMChain agent loop with tool-calling, against a mock
  get_flow tool (Tools.get_flow/0) standing in for the real MCP call until
  its endpoint/auth details are wired in. No LangFuse-equivalent tracing yet.
  """
  use Plug.Router

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias AiServiceElixir.Tools

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  @mcp_base_domain System.get_env("MCP_BASE_DOMAIN", "")

  # MCP is per-org, not one fixed endpoint: api.<shortcode>.<base_domain>.
  defp mcp_url_for(shortcode), do: "https://api.#{shortcode}.#{@mcp_base_domain}"

  get "/health" do
    send_json(conn, 200, %{status: "ok", mcp_configured: @mcp_base_domain != ""})
  end

  post "/run" do
    %{"job_id" => job_id, "skill_name" => skill_name, "content" => content} = conn.body_params
    flow_id = content["flow_id"]

    prompt =
      "Review flow #{flow_id}. Call get_flow to read its structure, " <>
        "then summarize what it does and flag anything that looks wrong."

    {:ok, updated_chain} =
      %{
        llm:
          ChatAnthropic.new!(%{
            model: "claude-sonnet-4-5-20250929",
            stream: false,
            api_key: System.get_env("ANTHROPIC_API_KEY")
          })
      }
      |> LLMChain.new!()
      |> LLMChain.add_tools([Tools.get_flow()])
      |> LLMChain.add_message(Message.new_user!(prompt))
      |> LLMChain.run(mode: :while_needs_response)

    tools_called =
      updated_chain.exchanged_messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.flat_map(fn m -> Enum.map(m.tool_results || [], & &1.name) end)

    result = %{
      skill_name: skill_name,
      answer: updated_chain.last_message.content,
      tools_called: tools_called
    }

    send_json(conn, 200, %{job_id: job_id, result: result, cost_tokens: 0})
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
