# Issue 01 — tmux as claude wrapper: still needed post-erlexec PTY?

Closed 2026-05-01.

## TLDR

- **Problem:** tonight's PR-21κ live-test surfaced a zombie-session bug — when the tmux server backing a CC session dies (manual kill, claude crash, host reboot), `TmuxProcess.on_terminate` fires but `cc_process` / FCP / `SessionRegistry` don't notice. Next inbound routes into a dead path. Worked around by full BEAM kickstart. The deeper question: **is tmux still earning its keep?**
- **Decision:** **Keep tmux.** Fix the zombie via back-wire-on-restart (approach D), not via session teardown.
- **Why:** Operator multi-attach (副驾) is a daily-used workflow; erlexec PTY is point-to-point and can't multi-attach without re-implementing tmux. So the only option that preserves UX is keeping tmux. The zombie symptom was supervisor strategy + missing back-wire, not a tmux-vs-erlexec architectural issue.
- **Where it landed:** PR-21ψ — `TmuxProcess.init/1` calls `rewire_session_siblings/1` which `:sys.replace_state`-patches the new tmux pid into FCP / cc_process `state.neighbors[:tmux_process]`. Repeated crashes cascade naturally via DynamicSupervisor's `max_restarts/max_seconds` thresholds → the outer `Esr.Session` `:one_for_all` supervisor tears the session down → next inbound auto-creates fresh.

## Context

ESR runs claude inside `tmux -C` (control mode). Process tree:

```
BEAM (esrd)
└─ erlexec (Esr.OSProcess)
   └─ tmux -C new-session ...
      └─ /bin/sh -c "scripts/esr-cc.sh"
         └─ exec claude ...
```

### Why tmux was chosen (pre-PR-21β)

Before the erlexec migration, the worker layer used `bash & disown` —
no BEAM-bound lifecycle, manual orphan cleanup. Tmux gave us:

1. **PTY** for claude (it needs a TTY to render its UI)
2. **Multi-attach**: operator can `tmux -S <socket> attach -t esr_cc_<N>`
   and *see* claude's screen, *type* into it alongside the bot — the
   "operator copilot" workflow that motivated tmux over a plain pipe.
3. **`tmux send-keys`** for Elixir-controlled input (T12a auto-confirms
   the trust-folder dialog this way)
4. **`tmux capture-pane`** to read claude's screen state on demand

### What changed (PR-21β, 2026-04-30)

`Esr.WorkerSupervisor` migrated to erlexec (`Esr.OSProcess` base). erlexec
does support PTY (`pty: true` option). So we now have a path to spawning
claude *directly* via erlexec without tmux.

## The question

Is tmux still required? Or can we drop it for direct erlexec PTY?

### What tmux provides that erlexec PTY doesn't

| Capability | tmux | erlexec PTY |
|---|---|---|
| BEAM-bound lifecycle | ✅ (via erlexec) | ✅ |
| PTY for claude | ✅ | ✅ |
| Multi-attach (operator copilot) | ✅ | ❌ |
| `send-keys` to inject input | ✅ | ✅ (`:exec.send/2`) |
| Capture screen state | ✅ (`capture-pane`) | ❌ (only stdout stream) |
| Survives BEAM restart | configurable | ❌ |

The two real differences: **multi-attach** and **capture-pane**.

### What zombie session looks like under each

**Today (tmux):** tmux server dies independently → BEAM TmuxProcess
detects via `on_terminate` → but cc_process etc. don't know → next
inbound routes into the now-empty session → silent UX failure.

**Post-tmux (erlexec PTY direct):** if claude dies, erlexec reports
exit → `Esr.OSProcess` cascades to peer crash → supervisor strategy
decides whether to restart or tear down the session. The "tmux died
but claude alive" failure mode disappears entirely (no separate tmux
server to die).

## Approaches under consideration

**A) Keep tmux, fix zombie cascade** (~50–100 LOC)

`TmuxProcess.on_terminate` triggers
`Esr.SessionRegistry.unregister_session/1` for its own session, plus
broadcasts a `:session_terminated` PubSub event so cc_process / FCP
gracefully stop. Or change session supervisor strategy to
`:one_for_all` so any peer death tears the session down — re-routing
auto-creates fresh.

**B) Drop tmux, use erlexec PTY direct** (~300 LOC + tests + docs)

`Esr.Peers.TmuxProcess` → `Esr.Peers.PtyProcess`. Loses multi-attach
and capture-pane. Cleaner architecture, no zombie shape, no `tmux send-keys`
quoting hazards, no socket file management. Simpler PR-21θ-style cwd
plumbing (no tmux `-c` flag). But operator can no longer attach to
claude's session for copilot.

**C) Hybrid: erlexec PTY default, tmux opt-in** (~400 LOC, two code paths)

Per-agent (or per-session) `attachable: true|false`. Default fast
path: erlexec direct (no zombie, simpler). Operator wanting copilot
sets `attachable: true` and gets the tmux wrapper.

## Open questions for the user

1. Is operator-attaches-to-claude-alongside-bot a real workflow you
   use, or aspirational?
2. If real: how often? Daily? Once a week? Once a month?
3. If we drop tmux, what's the fallback for the "I want to see what
   claude is doing in real time" case? (Channel logs? `tail -f` on
   stdout capture?)

## References

- `docs/notes/erlexec-worker-lifecycle.md` (post-PR-21β)
- `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`
  §FeishuChatProxy / §TmuxProcess
- `runtime/lib/esr/peers/tmux_process.ex` (current)
- `runtime/lib/esr/os_process.ex` (erlexec base)
- `docs/futures/todo.md` "Reliability: tmux-death zombie session" (PR-21φ)
