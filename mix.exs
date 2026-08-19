defmodule AiServiceElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :ai_service_elixir,
      version: "0.2.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {AiServiceElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:langchain, "~> 0.9"},
      # FR-3: no checkpointer exists for elixir-langchain, so the thread store
      # is hand-written against Postgres directly. See ThreadStore.
      {:postgrex, "~> 0.19"},
      # FR-4: no MCP client exists either -- McpClient speaks JSON-RPC over
      # HTTP by hand. req arrives transitively via langchain but is declared
      # here because we use it directly.
      {:req, "~> 0.5"}
    ]
  end
end
