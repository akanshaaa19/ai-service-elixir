# AI Service — Elixir sandbox (elixir-langchain)

Isolated capability test for [`elixir-langchain`](https://github.com/brainlid/langchain), decoupled from Glific's own dependency tree.

**Why isolated, not inside Glific:** an earlier attempt to add `elixir-langchain` directly into Glific's app hit a real, unresolvable conflict — `langchain >= 0.3.0` needs `req >= 0.5.2`, which needs `mime ~> 2.x`, but `google_gax` (pulled in by Glific's BigQuery/Dialogflow/Sheets/Translate integrations) is capped at `mime ~> 1.0` with no newer release available. Full writeup: `plans/ai-orchestration/sandbox-testing-log.md` in the main `glific` repo.

This repo exists to answer a different, decoupled question: does `elixir-langchain` itself do what we need (tool-calling, multi-step agent loop, multi-provider), independent of whether it can live inside Glific's existing app.

## Status

Step 2 scope only (prove the wire): `/health` and `/run` (echo), no real `LangChain.Chains.LLMChain` run yet.

## Run locally

```
mix deps.get
mix run --no-halt   # listens on 4002 (4001 collides with Glific dev HTTPS)
```
