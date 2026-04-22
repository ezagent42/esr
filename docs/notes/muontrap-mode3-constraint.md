# MuonTrap 1.7 Wrapper: the Three-Way Constraint

## Context

Discovered 2026-04-22 during PR-1 task P1-6 (`Esr.TmuxProcess`). The subagent implementing tmux `-C` control-mode integration wired everything per the plan's code, but the integration test hung — `%begin`/`%end` events never reached BEAM. Empirical investigation (verified via a standalone `cat` stdin-echo reproducer and a reading of `deps/muontrap/c_src/muontrap.c:196-213`) produced the finding below.

## Observation

The `muontrap` wrapper binary (distributed with the Hex package, located via `MuonTrap.muontrap_path/0`) cannot simultaneously provide **all three** of the following:

| Property | Needed for |
|---|---|
| **A. Write to child's stdin from Elixir** (via `Port.command/2`) | Interactive sidecars (tmux control mode, Python JSON-line RPC, shell automation) |
| **B. Read child's stdout in Elixir** (via Port `{:line, N}` messages) | Same as A — get structured output back |
| **C. Guarantee cleanup of child on BEAM exit** (including SIGKILL) | Production safety — no orphan processes |

**Without `--capture-output` flag**:
- The muontrap binary redirects the child's stdout + stderr to `/dev/null` at the `dup2` level (muontrap.c L196-213).
- Result: child's stdout never reaches BEAM. Property B broken.
- Properties A and C work.

**With `--capture-output` flag** (intended remedy):
- The muontrap binary treats its OWN stdin as the "ack byte-counting channel" per `MuonTrap.Port.encode_acks/1`. Every byte written by Elixir's `Port.command/2` is decoded as an ack-count integer.
- Result: bytes written by Elixir are consumed by muontrap itself; they never reach the child. Worse, large writes overflow the `stdio_bytes_max` threshold and muontrap exits the child with failure.
- Property A broken.
- Properties B and C work.

**Without the muontrap wrapper at all** (plain `Port.open({:spawn_executable, "tmux"}, ...)`):
- Properties A and B work.
- Property C is at the mercy of the OS: macOS / Linux may or may not kill children when BEAM dies abruptly. For well-behaved children (tmux, Python), closing stdin (which happens automatically when the Port dies) triggers their own cleanup. For other children, orphans are possible.

## Implication

1. `Esr.OSProcess` cannot use a single code path for all peer types.
2. Peers that only need cleanup guarantees (e.g. a fire-and-forget `sleep` daemon, a background worker that prints no output we care about) use **wrapper: :muontrap** — get properties A⊘, B⊘, **C✓**.
   - Actually stdout is lost here, but peer design ignores it. Property A is also unused (no stdin writes expected).
3. Peers that need interactive I/O (tmux, Python sidecars, shell REPLs) use **wrapper: :none** — get properties **A✓, B✓**, C⊘ (delegated to the child's own EOF-detection or to app-level `terminate/2` cleanup).

## Mitigation (implemented in PR-1)

`Esr.OSProcess` behaviour takes a `:wrapper` option:

```elixir
defmodule Esr.TmuxProcess do
  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :tmux, wrapper: :none  # ← interactive
  # ...
  def terminate(_reason, state) do
    # app-level cleanup — guaranteed by the Peer's supervisor exit cascade
    System.cmd("tmux", ["kill-session", "-t", state.session_name])
    :ok
  end
end

defmodule Esr.PyProcess do
  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :python, wrapper: :none  # ← interactive
  # Python's stdin loop hits EOF when Port closes → clean exit, no app code needed
end

defmodule Esr.Peers.BackgroundTask do
  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :background, wrapper: :muontrap  # ← cleanup-critical, no I/O
end
```

Default is `:muontrap` (safer). Peers that need stdin/stdout must opt into `:none` explicitly and document their cleanup path.

## Future

- **Update `muontrap-elixir` skill**: the current SKILL.md describes a "Mode 3" that claims all three properties. It's wrong. Plan: split into Mode 3a (stdin-only), Mode 3b (stdout+cleanup), Mode 3c (bidirectional interactive, no wrapper). Run skill-creator iteration-2 before PR-2.
- **Revisit with erlexec**: GitHub issue #7 proposes `erlexec` as an alternative底座. `erlexec` has a more flexible stdin/stdout/cleanup protocol — it may provide all three properties without a trade-off. If PR-1's approach hits further friction, consider switching.
- **Upstream PR to muontrap**: the `--capture-output` + `--allow-stdin` combination (or equivalent) would resolve this. If / when we have capacity to contribute, worth a PR to `fhunleth/muontrap`.

## Evidence links

- `deps/muontrap/c_src/muontrap.c:196-213` — `stdout` → `/dev/null` behaviour without `--capture-output`
- `deps/muontrap/lib/muontrap/port.ex` `encode_acks/1` — stdin-as-ack-channel when `--capture-output` is on
- `feature/peer-session-refactor` commit `28055a2` (PR-1 P1-6) — introduces the `wrapper: :muontrap | :none` split
- SKILL: `.claude/skills/muontrap-elixir/SKILL.md` — needs update per future-work item above
