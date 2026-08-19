defmodule AiServiceElixir.Application do
  @moduledoc false
  use Application

  alias AiServiceElixir.{McpClient, ThreadStore}

  @impl true
  def start(_type, _args) do
    # 4002, not 4001: Glific's own dev HTTPS endpoint binds 4001, so the old
    # default made the two impossible to run side by side -- which is exactly
    # what a demo against Glific needs.
    port = String.to_integer(System.get_env("PORT", "4002"))

    children =
      [
        # Postgrex first -- ThreadStore.ensure_schema/0 needs it up.
        ThreadStore.child_spec_or_nil(),
        McpClient,
        {Bandit, plug: AiServiceElixir.Router, port: port}
      ]
      |> Enum.reject(&is_nil/1)

    result = Supervisor.start_link(children, strategy: :one_for_one, name: AiServiceElixir.Supervisor)

    ThreadStore.ensure_schema()

    result
  end
end
