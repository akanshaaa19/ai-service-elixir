defmodule AiServiceElixir.Router do
  @moduledoc """
  AI Service — pure-Elixir sandbox variant (elixir-langchain).

  Step 2 scope only (per the integration kickoff plan): prove the wire between
  Glific and this service. Echoes back what it's given — no LangChain.LLMChain
  run, no MCP call yet. Those land once this round-trip is confirmed working.
  """
  use Plug.Router

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

    result = %{echo: content, skill_name: skill_name}
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
