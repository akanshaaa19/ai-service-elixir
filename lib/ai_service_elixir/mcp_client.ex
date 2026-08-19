defmodule AiServiceElixir.McpClient do
  @moduledoc """
  FR-4 -- a hand-written MCP client.

  ## Why this module exists

  `elixir-langchain` has no MCP support of any kind, and there is no
  general-purpose MCP client package for Elixir we could adopt (`jido_mcp`
  exists but is 3 releases old with ~1.4k downloads and is coupled to Jido's
  agent model). So the entire protocol is implemented here: the initialize
  handshake, session-id tracking, tool discovery, and tool invocation --
  including the fact that a streamable-HTTP MCP server may answer either
  `application/json` or `text/event-stream` for the *same* request, so both
  framings have to be parsed.

  On the Python side this whole file is one dependency and two lines.

  State is a GenServer because the MCP session id issued by `initialize` has
  to be carried on every subsequent request.
  """

  use GenServer
  require Logger

  alias LangChain.Function

  @protocol_version "2025-06-18"

  ## Client API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "All tools the server exposes, as LangChain functions. [] when unconfigured."
  def tools, do: GenServer.call(__MODULE__, :tools, 30_000)

  @doc "Whether a real MCP session was established."
  def configured?, do: GenServer.call(__MODULE__, :configured?)

  @doc "Call one MCP tool by name."
  def call_tool(name, args), do: GenServer.call(__MODULE__, {:call_tool, name, args}, 60_000)

  ## Server

  @impl true
  def init(_opts) do
    # Connect lazily: a dead MCP server must not stop the service booting.
    {:ok, %{session_id: nil, tools: [], connected?: false}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    if url() == "" do
      Logger.warning("MCP not configured (GLIFIC_MCP_URL unset) -- falling back to mock tool")
      {:noreply, state}
    else
      {:noreply, connect(state)}
    end
  end

  @impl true
  def handle_call(:tools, _from, state) do
    tools = if state.connected?, do: state.tools, else: [mock_tool()]
    {:reply, tools, state}
  end

  def handle_call(:configured?, _from, state), do: {:reply, state.connected?, state}

  def handle_call({:call_tool, name, args}, _from, state) do
    {:reply, do_call_tool(state, name, args), state}
  end

  ## Protocol

  defp connect(state) do
    with {:ok, session_id, _result} <- initialize(),
         :ok <- notify_initialized(session_id),
         {:ok, specs} <- list_tools(session_id) do
      Logger.info("MCP connected: #{length(specs)} tools -- #{Enum.map_join(specs, ", ", & &1["name"])}")
      %{state | session_id: session_id, tools: Enum.map(specs, &to_function/1), connected?: true}
    else
      {:error, reason} ->
        Logger.error("MCP connect failed: #{inspect(reason)} -- falling back to mock tool")
        state
    end
  end

  defp initialize do
    body = rpc("initialize", %{
      protocolVersion: @protocol_version,
      capabilities: %{},
      clientInfo: %{name: "ai-service-elixir", version: "0.2.0"}
    }, 1)

    case post(body, nil) do
      {:ok, resp} ->
        # The session id comes back as a *header*, not in the JSON body.
        session_id =
          resp.headers
          |> Enum.find_value(fn {k, v} ->
            if String.downcase(k) == "mcp-session-id", do: List.wrap(v) |> List.first()
          end)

        case decode(resp) do
          {:ok, %{"result" => result}} -> {:ok, session_id, result}
          {:ok, other} -> {:error, {:unexpected_initialize_response, other}}
          error -> error
        end

      error ->
        error
    end
  end

  defp notify_initialized(session_id) do
    # A notification has no id and expects no result.
    case post(%{jsonrpc: "2.0", method: "notifications/initialized"}, session_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp list_tools(session_id) do
    with {:ok, resp} <- post(rpc("tools/list", %{}, 2), session_id),
         {:ok, %{"result" => %{"tools" => tools}}} <- decode(resp) do
      {:ok, tools}
    else
      {:ok, other} -> {:error, {:unexpected_tools_list, other}}
      error -> error
    end
  end

  defp do_call_tool(%{connected?: false}, name, _args),
    do: {:error, "MCP not connected; cannot call #{name}"}

  defp do_call_tool(%{session_id: session_id}, name, args) do
    with {:ok, resp} <-
           post(rpc("tools/call", %{name: name, arguments: args}, System.unique_integer([:positive])), session_id),
         {:ok, decoded} <- decode(resp) do
      case decoded do
        %{"result" => %{"content" => content}} -> {:ok, flatten_content(content)}
        %{"result" => result} -> {:ok, Jason.encode!(result)}
        %{"error" => error} -> {:error, "MCP tool error: #{inspect(error)}"}
        other -> {:error, "unexpected tool response: #{inspect(other)}"}
      end
    end
  end

  # MCP tool results are a list of content blocks; keep the text ones.
  defp flatten_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  defp flatten_content(other), do: Jason.encode!(other)

  ## HTTP

  defp post(body, session_id) do
    headers =
      [
        {"content-type", "application/json"},
        # Must accept BOTH -- a streamable-HTTP server picks either framing.
        {"accept", "application/json, text/event-stream"},
        {"x-glific-base-url", env("GLIFIC_BASE_URL")},
        {"x-glific-phone", env("GLIFIC_PHONE")},
        {"x-glific-password", env("GLIFIC_PASSWORD")}
      ] ++ if(session_id, do: [{"mcp-session-id", session_id}], else: [])

    case Req.post(url(), json: body, headers: headers, receive_timeout: 60_000, retry: false) do
      {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, error} -> {:error, error}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # A streamable-HTTP MCP response may be a JSON object or an SSE stream
  # carrying the same object in a `data:` line. Req decodes the former for us
  # and hands back the latter as a raw string, so handle both.
  defp decode(%{body: body}) when is_map(body), do: {:ok, body}

  defp decode(%{body: body}) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&(&1 |> String.replace_prefix("data:", "") |> String.trim()))
    |> Enum.reverse()
    |> Enum.find_value({:error, {:undecodable, String.slice(body, 0, 200)}}, fn chunk ->
      case Jason.decode(chunk) do
        {:ok, decoded} -> {:ok, decoded}
        _ -> nil
      end
    end)
  end

  defp decode(%{body: body}), do: {:error, {:undecodable, inspect(body)}}

  defp rpc(method, params, id), do: %{jsonrpc: "2.0", id: id, method: method, params: params}

  defp url, do: env("GLIFIC_MCP_URL")
  defp env(key), do: System.get_env(key, "")

  ## LangChain bridge

  # Every MCP tool becomes a LangChain.Function whose implementation proxies
  # back through this GenServer.
  defp to_function(%{"name" => name} = spec) do
    Function.new!(%{
      name: name,
      description: spec["description"] || name,
      parameters_schema: spec["inputSchema"] || %{"type" => "object", "properties" => %{}},
      function: fn args, _context ->
        case call_tool(name, args) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:ok, "Tool #{name} failed: #{inspect(reason)}"}
        end
      end
    })
  end

  defp mock_tool do
    Function.new!(%{
      name: "get_flow_mock",
      description: "Fetch a flow's structure by ID. Returns nodes and their exits. MOCK DATA.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"flow_id" => %{"type" => "integer"}},
        "required" => ["flow_id"]
      },
      function: fn args, _context ->
        {:ok,
         Jason.encode!(%{
           flow_id: args["flow_id"],
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
