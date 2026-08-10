defmodule AiServiceElixir.Tools do
  @moduledoc """
  Mock MCP tools, standing in for real Glific MCP calls until the real
  endpoint/auth details (api.<shortcode>.<base_domain>, staff creds) are
  wired in. Same shape the real tool will have, so swapping the function
  body for a real HTTP call later doesn't change the agent loop at all.
  """
  alias LangChain.Function

  def get_flow do
    Function.new!(%{
      name: "get_flow",
      description: "Fetch a flow's structure by ID. Returns nodes and their exits.",
      parameters_schema: %{
        type: "object",
        properties: %{
          flow_id: %{type: "integer", description: "The flow ID to fetch"}
        },
        required: ["flow_id"]
      },
      function: fn %{"flow_id" => flow_id}, _context ->
        {:ok,
         Jason.encode!(%{
           flow_id: flow_id,
           name: "Sandbox test flow",
           nodes: [
             %{uuid: "n1", type: "send_msg", text: "Welcome!", exits: ["n2"]},
             %{uuid: "n2", type: "wait_for_response", exits: ["n3", nil]},
             %{uuid: "n3", type: "send_msg", text: "Thanks!", exits: []}
           ]
         })}
      end
    })
  end
end
