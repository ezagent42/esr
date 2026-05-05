defmodule Esr.Slash.ReplyTarget do
  @moduledoc """
  Phase 2 PR-2.2: dependency-inversion boundary between
  `Esr.Entity.SlashHandler` and the four reply-emitting destinations:
  chat (FCP), admin file queue, stdout (CLI), and Phoenix.Channel (REPL).

  ## Why a behaviour

  Today's SlashHandler hardcodes `send(pid, {:reply, text, ref})`. Three
  upcoming consumers — escript (PR-2.5/2.6), REPL (PR-2.8), and the
  admin-queue rewrite (PR-2.3b) — need different reply mechanics.
  Without inversion, each would reach into SlashHandler internals and
  fork the dispatch path. With this behaviour, every consumer receives
  the same dispatch contract; only the impl differs.

  Per North Star (memory rule 2026-05-05 plugin isolation): plugins
  that contribute slash commands never need to know how the reply is
  delivered. They write to the contract; the impl varies.

  ## Contract

  An impl receives:
    * `target` — opaque to SlashHandler; whatever the impl needed to
      stash at dispatch time (a pid, a file path, an open IO device,
      a channel topic). Format is the impl's business.
    * `result` — either:
        - a result map from `Esr.Commands.<X>.execute/2` (success or
          structured error), in which case the impl decides how to
          render it for its medium; OR
        - a `{:text, String.t()}` tuple for synthetic errors
          (unknown-command, timeout, validation) where SlashHandler
          has no map to pass.
    * `ref` — the dispatch reference. ChatPid uses it to correlate
      reply with caller's `slash_pending_chat`; CLI/file impls
      typically ignore it.

  Impls return `:ok` on success or `{:error, term}` on delivery
  failure (e.g. file write error). SlashHandler treats `{:error, _}`
  as best-effort failure: it logs and moves on.

  ## Available impls

    * `Esr.Slash.ReplyTarget.ChatPid` — `send(pid, {:reply, text, ref})`.
      The current Feishu-chat path. Backwards-compat: bare pids passed
      to `SlashHandler.dispatch/2,3` are auto-wrapped as `{ChatPid, pid}`.
    * `Esr.Slash.ReplyTarget.IO` — `IO.puts/2` to a configurable device
      (defaults to `:stdio`). Used by the escript one-shot path
      (`esr exec /<slash>`); also useful in tests.
    * `Esr.Slash.ReplyTarget.QueueFile` — stub in PR-2.2; implemented
      in PR-2.3a/b alongside `Esr.Slash.QueueResult`. Writes structured
      yaml to `~/.esrd/<env>/admin_queue/completed/<id>.yaml`.
    * `Esr.Slash.ReplyTarget.WS` — stub in PR-2.2; implemented in PR-2.8
      for the REPL session.

  ## Surface kept narrow

  Only `respond/3` is required. No phase callbacks (on_accept,
  on_complete, on_failed) at this level — the QueueFile impl handles
  its own state-machine internally because no other impl needs that
  shape.
  """

  @type target :: term()
  @type result :: {:text, String.t()} | term()

  @callback respond(target(), result(), reference()) :: :ok | {:error, term()}

  @doc """
  Normalize a reply destination to the `{module, target}` tuple shape.

  Accepts:
    * a plain pid → wrapped as `{ChatPid, pid}` (backwards-compat for
      the legacy `SlashHandler.dispatch(envelope, pid)` arity).
    * a `{module, target}` tuple → returned unchanged after a sanity
      check that `module` exports `respond/3`.

  Raises ArgumentError on any other shape.
  """
  @spec normalize(pid() | {module(), term()}) :: {module(), term()}
  def normalize(pid) when is_pid(pid), do: {Esr.Slash.ReplyTarget.ChatPid, pid}

  def normalize({mod, target}) when is_atom(mod) do
    {mod, target}
  end

  def normalize(other) do
    raise ArgumentError,
          "Esr.Slash.ReplyTarget.normalize/1: expected pid or {module, target}, got #{inspect(other)}"
  end

  @doc """
  Dispatch `respond/3` to the impl module. Catches and logs delivery
  exceptions so a buggy impl never crashes SlashHandler.
  """
  @spec dispatch({module(), term()}, result(), reference()) :: :ok | {:error, term()}
  def dispatch({mod, target}, result, ref) do
    try do
      mod.respond(target, result, ref)
    rescue
      e ->
        require Logger

        Logger.warning(
          "Esr.Slash.ReplyTarget.dispatch: #{inspect(mod)}.respond/3 raised " <>
            "#{Exception.format(:error, e, __STACKTRACE__)}"
        )

        {:error, {:respond_raised, e}}
    end
  end
end
