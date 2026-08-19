defmodule AiServiceElixir.Skills do
  @moduledoc """
  FR-1 -- the skill interpreter.

  Same contract as the Python side: this service never knows what
  "flow-review" means. Glific sends the definition inside `/run` and this
  module executes whatever it is handed. Adding a skill is an `ai_skills`
  row, not code here.

  FR-12 -- also holds the router, which picks a skill from the menu when the
  caller supplies no skill at all.
  """

  require Logger

  alias AiServiceElixir.{McpClient, ThreadStore}
  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message

  @default_prompt """
  You are the Glific copilot, helping staff at an NGO that uses Glific for \
  WhatsApp programs. Answer their question directly. Use the available read \
  tools to ground anything specific to their account -- never guess at their \
  real data.
  """

  @doc "Only the tools a skill declares; all of them when it declares none."
  def select_tools(tools, nil), do: tools
  def select_tools(tools, []), do: tools

  def select_tools(tools, allowed) when is_list(allowed) do
    case Enum.filter(tools, &(&1.name in allowed)) do
      [] -> tools
      selected -> selected
    end
  end

  @doc """
  Substitute `$input.<key>` references in a context declaration against the
  message content. Missing keys resolve to nil rather than raising.
  """
  def resolve_params(params, content) when is_map(params) do
    Map.new(params, fn
      {key, "$input." <> field} -> {key, Map.get(content, field)}
      {key, value} -> {key, value}
    end)
  end

  def resolve_params(_params, _content), do: %{}

  @doc """
  Run the skill's declared `context` entries before the model sees anything --
  the grounding step. A failing context call is reported into the context
  rather than aborting the run.
  """
  def prefetch_context(skill, content) do
    (skill["context"] || [])
    |> Enum.map(fn entry ->
      name = entry["tool"]
      args = resolve_params(entry["params"] || %{}, content)

      case McpClient.call_tool(name, args) do
        {:ok, result} -> "[context] #{name}(#{Jason.encode!(args)}) returned:\n#{result}"
        {:error, reason} -> "[context] #{name}(#{Jason.encode!(args)}) failed: #{inspect(reason)}"
      end
    end)
  end

  @doc "The skill's own prompt, plus whatever its context declarations fetched."
  def system_prompt(skill, context_blocks) do
    base = skill["prompt"] || @default_prompt

    grounding =
      if context_blocks == [] do
        []
      else
        [
          "You have been given the following data from this organisation's live " <>
            "Glific account. Ground your answer in it. Do not invent flow names, " <>
            "node ids, or template names that do not appear in it or in a tool result."
          | context_blocks
        ]
      end

    schema =
      case skill["output_schema"] do
        nil -> []
        s -> ["Shape your final answer to this output schema:\n#{Jason.encode!(s)}"]
      end

    Enum.join([base] ++ grounding ++ schema, "\n\n")
  end

  @doc "What the person actually asked."
  def user_text(%{"text" => text}) when is_binary(text) and text != "", do: text

  def user_text(content),
    do: "Run this skill against the following input:\n#{Jason.encode!(content)}"

  @doc """
  FR-12 -- pick a skill from the menu, or nil for a general copilot turn.

  Uses a plain model call with a strict instruction rather than structured
  output: elixir-langchain has no `with_structured_output` equivalent, so the
  contract is enforced by parsing and validating the reply ourselves. That is
  the same shape of extra work as ThreadStore and McpClient -- a primitive the
  Python library provides that has to be hand-rolled here.
  """
  def route(_text, []), do: {nil, "no skills registered"}

  def route(text, menu) do
    rendered =
      Enum.map_join(menu, "\n", fn s ->
        "- #{s["name"]}: #{s["description"] || "(no description)"}"
      end)

    prompt = """
    You route a Glific staff member's message to the right skill.

    Available skills:
    #{rendered}

    Reply with ONLY the exact skill name that best matches what the person is \
    asking for, and nothing else. If none of them genuinely fit -- a general \
    question, a greeting, or something no skill covers -- reply with exactly \
    NONE. Do not explain. Do not force a match.
    """

    with {:ok, chain} <-
           %{llm: anthropic()}
           |> LLMChain.new!()
           |> LLMChain.add_message(Message.new_system!(prompt))
           |> LLMChain.add_message(Message.new_user!(text))
           |> LLMChain.run() do
      chain.last_message.content
      |> ThreadStore.text_of()
      |> String.trim()
      |> validate_route(menu)
    else
      error ->
        Logger.error("router failed: #{inspect(error)}")
        {nil, "router failed"}
    end
  end

  # A model can name a skill that isn't on the menu. Treat that as no match
  # rather than passing an unknown name downstream.
  defp validate_route("NONE", _menu), do: {nil, "no skill fits"}

  defp validate_route(name, menu) do
    if Enum.any?(menu, &(&1["name"] == name)) do
      {name, "matched menu entry"}
    else
      Logger.warning("router picked unknown skill #{inspect(name)}; falling back to general")
      {nil, "router named unknown skill #{inspect(name)}"}
    end
  end

  @doc "A configured Anthropic chat model."
  def anthropic do
    ChatAnthropic.new!(%{
      model: System.get_env("AI_MODEL", "claude-opus-5"),
      stream: false,
      # Does not read ANTHROPIC_API_KEY from the environment on its own,
      # unlike the Python client -- must be passed explicitly.
      api_key: System.get_env("ANTHROPIC_API_KEY")
    })
  end
end
