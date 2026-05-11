defmodule Esr.Slash.ReplyTarget.RawCollector do
  @moduledoc """
  ReplyTarget impl that forwards the raw slash result to a caller process
  as `{:slash_raw, ref, result_or_error}`.

  Used by the `submit_slash` MCP tool path (PR-4 of the 2026-05-11
  default-agent + agent-driven-flow plan) so that the agent (CC) receives
  the structured result map for `Esr.Commands.<X>.execute/2` rather than
  the chat-rendered text that `ChatPid` produces.

  ## Contract

  The `target` is a 2-key map `%{caller: pid(), ref: reference()}`:

    * `caller` — process that will receive the `{:slash_raw, ref, ...}`
      message. Typically the per-call `Task` spawned by FCP's
      `submit_slash` branch (see `feishu_chat_proxy.ex`).
    * `ref` — caller-supplied correlation reference. The
      slash-dispatch ref returned by `SlashHandler.dispatch/2` is NOT
      reused here; the caller picks its own ref and matches it back.

  The third arg (`_slash_ref`) is the dispatch ref from SlashHandler
  itself — ignored, since the caller correlates on its own ref.

  ## Forwarded shapes

  Mirrors the result shape SlashHandler emits:
    * `{:ok, result_map}` → `{:slash_raw, ref, {:ok, result_map}}`
    * `{:error, reason}` → `{:slash_raw, ref, {:error, reason}}`
    * any other term → `{:slash_raw, ref, {:ok, term}}`
      (treated as a non-tagged success per SlashHandler convention)
  """

  @behaviour Esr.Slash.ReplyTarget

  @impl Esr.Slash.ReplyTarget
  def respond(%{caller: caller, ref: ref}, {:ok, result}, _slash_ref) do
    send(caller, {:slash_raw, ref, {:ok, result}})
    :ok
  end

  def respond(%{caller: caller, ref: ref}, {:error, reason}, _slash_ref) do
    send(caller, {:slash_raw, ref, {:error, reason}})
    :ok
  end

  def respond(%{caller: caller, ref: ref}, result, _slash_ref) do
    send(caller, {:slash_raw, ref, {:ok, result}})
    :ok
  end
end
