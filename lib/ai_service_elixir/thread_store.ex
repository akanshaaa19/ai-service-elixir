defmodule AiServiceElixir.ThreadStore do
  @moduledoc """
  FR-3 -- a hand-written conversation thread store.

  ## Why this module exists

  `elixir-langchain` has no checkpointer, no thread abstraction, and no
  persistence layer of any kind. An `LLMChain` holds its messages in a struct
  in the calling process and they vanish when the request ends. So durable,
  resumable threads had to be built from scratch: schema, migration-on-boot,
  serialization, and deserialization.

  On the Python side this is `AsyncPostgresSaver(pool)` plus a `thread_id` in
  the config map -- no schema, no serializer, and the checkpointer's own
  `setup()` creates its tables.

  ## Known fidelity limitation (this is the important part)

  We persist `role` and the *text* of each message. Tool calls and tool
  results are **not** round-tripped: their structure (`tool_calls`,
  `tool_results`, call ids) is lost, so a resumed thread reads as prose
  describing what happened rather than as a replayable tool exchange. That is
  usually fine for a chat transcript and is **not** fine as a checkpoint --
  the model cannot resume mid-tool-call, which is exactly what FR-7's
  propose/approve gate would need.

  LangGraph's checkpointer serializes the entire graph state losslessly
  (msgpack in JSONB) and can resume from any point. Closing that gap in
  Elixir means writing a real serializer for every LangChain message variant,
  which is well beyond a sandbox.
  """

  require Logger

  alias LangChain.Message

  @table "ai_threads"

  @doc "Create the table if absent. Called once at boot."
  def ensure_schema do
    if configured?() do
      query!("""
      CREATE TABLE IF NOT EXISTS #{@table} (
        thread_id  text PRIMARY KEY,
        messages   jsonb NOT NULL DEFAULT '[]'::jsonb,
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """)

      Logger.info("ThreadStore ready -- threads are durable")
      :ok
    else
      Logger.warning(
        "DATABASE_URL unset -- threads are NOT persisted. FR-3 is not satisfied in this mode."
      )

      :ok
    end
  end

  def configured?, do: System.get_env("DATABASE_URL", "") != ""

  @doc "Prior messages for a thread, oldest first, as LangChain messages."
  def load(nil), do: []

  def load(thread_id) do
    if configured?() do
      case query("SELECT messages FROM #{@table} WHERE thread_id = $1", [thread_id]) do
        {:ok, %{rows: [[messages]]}} -> Enum.map(messages, &deserialize/1)
        _ -> []
      end
    else
      []
    end
  end

  @doc "Raw stored transcript, for the read-back endpoint."
  def raw(thread_id) do
    if configured?() do
      case query("SELECT messages FROM #{@table} WHERE thread_id = $1", [thread_id]) do
        {:ok, %{rows: [[messages]]}} -> messages
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Append this turn's messages to the thread.

  Read-modify-write rather than a jsonb append, because the whole point is to
  keep this comparable to what the Python side gets for free -- and it makes
  the concurrency caveat explicit: two simultaneous turns on one thread can
  lose one of them. LangGraph's checkpointer versions each write instead.
  """
  def append(_thread_id, []), do: :ok

  def append(thread_id, new_messages) when is_list(new_messages) do
    if configured?() do
      serialized = Enum.map(new_messages, &serialize/1)
      existing = raw(thread_id)
      merged = existing ++ serialized

      query!(
        """
        INSERT INTO #{@table} (thread_id, messages, updated_at)
        VALUES ($1, $2, now())
        ON CONFLICT (thread_id)
        DO UPDATE SET messages = $2, updated_at = now()
        """,
        [thread_id, merged]
      )
    end

    :ok
  end

  ## Serialization -- see the fidelity limitation in the moduledoc

  defp serialize(%Message{} = message) do
    %{"role" => to_string(message.role), "content" => text_of(message.content)}
  end

  defp deserialize(%{"role" => "user", "content" => content}), do: Message.new_user!(content)

  defp deserialize(%{"role" => "assistant", "content" => content}),
    do: Message.new_assistant!(%{content: content})

  defp deserialize(%{"role" => "system", "content" => content}), do: Message.new_system!(content)

  # Tool messages can't be faithfully rebuilt (no call ids), so they come back
  # as assistant prose. Deliberate, and the reason for the caveat above.
  defp deserialize(%{"role" => role, "content" => content}),
    do: Message.new_assistant!(%{content: "[#{role}] #{content}"})

  @doc """
  elixir-langchain returns `content` as a list of ContentPart structs, where
  the Python client returns a plain string. Normalise to text.
  """
  def text_of(content) when is_binary(content), do: content

  def text_of(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{content: text} when is_binary(text) -> text
      %{"content" => text} when is_binary(text) -> text
      other -> to_string(inspect(other))
    end)
    |> Enum.join("")
  end

  def text_of(nil), do: ""
  def text_of(other), do: to_string(inspect(other))

  ## Postgrex plumbing

  defp query(sql, params), do: Postgrex.query(__MODULE__.Repo, sql, params)

  defp query!(sql, params \\ []) do
    case query(sql, params) do
      {:ok, result} ->
        result

      {:error, error} ->
        Logger.error("ThreadStore query failed: #{inspect(error)}")
        %{rows: []}
    end
  end

  @doc "Postgrex child spec, or nil when DATABASE_URL is unset."
  def child_spec_or_nil do
    if configured?() do
      uri = URI.parse(System.get_env("DATABASE_URL"))
      [user, pass] = String.split(uri.userinfo || "postgres:postgres", ":", parts: 2)

      Postgrex.child_spec(
        name: __MODULE__.Repo,
        hostname: uri.host || "localhost",
        port: uri.port || 5432,
        username: user,
        password: pass,
        database: String.trim_leading(uri.path || "/postgres", "/"),
        ssl: ssl_opts(uri)
      )
    end
  end

  # Managed Postgres usually requires TLS; local docker usually doesn't.
  defp ssl_opts(uri) do
    if uri.host in ["localhost", "127.0.0.1", nil], do: false, else: [verify: :verify_none]
  end
end
