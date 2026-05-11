# `(CC, PTY)` pair runs under `:one_for_all` — Esr.Session.AgentInstanceSupervisor

**Date:** 2026-05-11
**Status:** accepted
**Origin:** Q5.3 sub-2 (Feishu 2026-05-07 decision)

Each agent instance in a session is a `(CCProcess, PtyProcess)` pair.
The pair runs under a per-instance supervisor — `Esr.Session.AgentInstanceSupervisor`
at `runtime/lib/esr/session/agent_instance_supervisor.ex:40` — with
strategy `:one_for_all, max_restarts: 3, max_seconds: 60`.

## Why `:one_for_all`

The CC process holds a logical session against the PTY's tmux pane:
- CC writes stdin into the PTY.
- CC scrapes stdout from the PTY back into the MCP transport.

If the PTY dies and CC stays alive, CC is talking into the void —
writes go nowhere, reads see nothing, and the next user message lands
on a process that has no terminal to drive. The reverse — CC dies,
PTY stays alive — leaves an orphan tmux pane that no one will ever
read from again.

`:one_for_all` makes the pair atomic: either both processes are alive
and connected, or both are restarted as a fresh pair. The downstream
effect is that pid changes always come in synchronised twos —
InstanceRegistry's `cc_actor_id → pid` and `pty_actor_id → pid`
entries update together, the FCP resolves by name (not cached pid) so
the next message lands on the new instance, and there is no zombie
window where one half of the pair is alive.

## Why not `:one_for_one`

`:one_for_one` would restart the dead half only. The surviving half
would then race the new pid's registration:
- CC sends to the old PTY pid in `state.neighbors` → write to a dead
  process → no error surfaces because the message is just dropped on
  the floor (BEAM's mailbox semantics).
- PTY emits an output event with the old CC pid as the destination →
  the new CC never sees the output → the user's terminal hangs.

This was the failure mode that produced the historic "PtyProcess-death
zombie session" reliability bug, closed by PR #403 (2026-05-09). The
audit log: `docs/futures/todo.md` row entitled "Reliability:
PtyProcess-death zombie session".

## What this invariant guarantees

Any I3/I4 system invariant (see `docs/notes/system-invariants.md`)
that depends on "a session is either fully alive or fully dead" can
read this ADR for the supervisor-strategy half of the proof. The
LifecycleObserver (`runtime/lib/esr/session/lifecycle_observer.ex`,
PR-3 Task 3.7) handles the chat-visible reply when the supervisor
gives up after `max_restarts` — but the supervisor itself enforces
the all-or-nothing pair semantics.

## What this invariant does NOT guarantee

It does NOT prevent the *session-level* supervisor (`Esr.Session.Supervisor`)
from holding zombie peers when an agent instance's restart budget
exceeds `max_restarts: 3, max_seconds: 60`. That's the LifecycleObserver's
job — the observer monitors the session supervisor pid, fires when it
exits, and detaches the chat-routing slot so a fresh `/session:new`
can take its place.

## Consequences

- Any future change to `agent_instance_supervisor.ex`'s strategy
  field MUST update this ADR (supersede or amend) and the I3/I4 test
  rationale at the same time. The CI gate (`mix
  esr.audit_supervision`) catches *adds/removes* in the supervisor
  inventory but not strategy flips on existing supervisors. The
  diff-yourself-out-of-trouble half is human review on this file.

- Plugin authors writing new agent kinds (Phase B+) inherit the
  expectation that any peer pair which shares logical state should
  use `:one_for_all`. The CC + PTY pair is the canonical reference;
  voice gateway's (audio worker, RTC connection) pair follows the
  same rule.
