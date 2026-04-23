# erlexec Migration: Esr.OSProcess 底座 Switch

## Context

PR-3, commit `P3-17` (2026-04-22). `Esr.OSProcess` was rewritten to use
[`:erlexec`](https://hexdocs.pm/erlexec/) instead of the previous
`Port.open + muontrap` wrapper binary pattern. This note records the
decision, the code shape, and how to write new OSProcess-backed peers
in the erlexec world.

## Observation — why the switch

The previous底座 had a `:wrapper` choice between `:muontrap` and
`:none`, each broken in a different way for the peer types we actually
care about:

| Peer                  | Old wrapper  | Problem                                              |
|-----------------------|--------------|------------------------------------------------------|
| `Esr.Peers.TmuxProcess` | `:none`    | `tmux -C` on macOS exits immediately without a PTY — BEAM's `Port.open` does not allocate one, so `send_command/2` wrote to an already-dead stdin. Integration tests flaked (`tmux_process_test:162/:175`). |
| `Esr.PyProcess`       | `:none`      | Worked, but relied on the sidecar's EOF-on-stdin detection for cleanup — no kernel guarantee on BEAM SIGKILL. |
| hypothetical daemon   | `:muontrap`  | `--capture-output` repurposes wrapper stdin as an ack channel, so `Port.command/2` could not reach the child. See `muontrap-mode3-constraint.md`. |

`:erlexec` solves all three simultaneously:

1. **Native PTY** — `pty` option spawns the child under a real
   pseudo-terminal. `tmux -C` stops flaking.
2. **Bidirectional stdin/stdout** — `:exec.send/2` writes to the
   child's stdin with no ack-channel constraint; stdout arrives as
   `{:stdout, os_pid, data}` messages.
3. **BEAM-exit cleanup** — the erlexec `exec-port` C++ program watches
   its Erlang owner and kills every child when the owner dies, even on
   SIGKILL. Equivalent to muontrap's `prctl(PR_SET_PDEATHSIG)` /
   `kqueue EVFILT_PROC` mechanism, with the same per-platform coverage.

## What changed

### Dependency

`runtime/mix.exs`:

```elixir
{:erlexec, "~> 2.2"},      # new — the new底座
{:muontrap, "~> 1.7"},     # kept temporarily; not used by OSProcess anymore
```

`:erlexec` is in `extra_applications` so OTP auto-starts the `exec`
supervisor (which spawns the `exec-port` C++ program) before any peer
calls `:exec.run_link/2`.

### `Esr.OSProcess`

The macro now accepts `wrapper: :pty | :plain` (old `:muontrap | :none`
are gone). Signatures of `os_cmd/1`, `os_env/1`, `on_os_exit/2`,
`on_terminate/1` are unchanged — existing consumers only have to
flip the atom.

| Before (Port + muontrap)              | After (erlexec)                                   |
|---------------------------------------|---------------------------------------------------|
| `Port.open({:spawn_executable, muontrap_bin}, [...])` | `:exec.run_link(cmd, opts)` |
| `{port, {:data, {:eol, line}}}` messages | `{:stdout, os_pid, data}` + in-module `split_lines/1` |
| `{port, {:exit_status, n}}`           | `{:DOWN, os_pid, :process, pid, reason}` via `monitor`; `reason_to_status/1` normalizes |
| `Port.command(port, bytes)`           | `:exec.send(os_pid, bytes)` |
| `Port.info(port, :os_pid)`            | os_pid returned directly by `run_link/2`          |
| `Port.close(port)` in `terminate/2`   | `:exec.stop(os_pid)` (SIGTERM → 5s → SIGKILL)     |

Line framing needs a small accumulator (`Esr.OSProcess.split_lines/1`)
because erlexec doesn't offer a `{:line, N}` option like native Port
did. The helper also normalizes `\r\n` → `\n` so PTY-origin lines look
the same as plain lines to downstream parsers.

### Consumers

- `Esr.Peers.TmuxProcess`: `use Esr.OSProcess, kind: :tmux, wrapper: :pty`
  — the payoff case.
- `Esr.PyProcess`: `use Esr.OSProcess, kind: :python, wrapper: :plain`
  — no TTY needed, plain path is faster.

## Implication for future peers

When adding a new peer that wraps an OS process:

```elixir
defmodule Esr.Peers.MyPeer do
  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :my_peer, wrapper: :plain   # or :pty

  @impl Esr.OSProcess
  def os_cmd(state), do: ["my-binary", "--flag", state.arg]

  @impl Esr.OSProcess
  def os_env(_state), do: [{"FOO", "bar"}]

  @impl Esr.OSProcess
  def on_os_exit(0, _), do: {:stop, :normal}
  def on_os_exit(n, _), do: {:stop, {:exit_status, n}}

  @impl Esr.OSProcess
  def on_terminate(_state), do: :ok  # app-level cleanup hook

  @impl Esr.Peer.Stateful
  def handle_upstream({:os_stdout, line}, state) do
    # consume one line of child output
    {:forward, [{:my_event, line}], state}
  end
end
```

### Which wrapper to pick

- `wrapper: :pty` — the child needs a real terminal. Triggers:
  `isatty(0)` checks, ANSI color autodetection, job-control features,
  `tmux`, `script`, interactive REPLs. Output arrives with `\r\n` which
  we normalize to `\n`.
- `wrapper: :plain` — everything else. Faster. Use for JSON-line
  sidecars, structured RPC, plain stdout log output.

When unsure, start with `:plain`; switch to `:pty` only if empirical
behavior differs between terminal and pipe execution.

### What you get for free

- `write_stdin/2` — write bytes to the child via
  `<PeerModule>.OSProcessWorker.write_stdin(pid, bytes)`.
- `os_pid/1` — integer OS pid for external tooling.
- Line framing — lines are dispatched one at a time to
  `handle_upstream({:os_stdout, line}, state)` with `\n` preserved at
  the end (matches the old `{:line, 4096}` behavior).
- Cleanup on normal exit — `terminate/2` runs `on_terminate/1`, then
  `:exec.stop(os_pid)` SIGTERMs the child and escalates to SIGKILL
  after 5 seconds.
- Cleanup on BEAM hard-crash — erlexec's `exec-port` C++ program
  watches the owning BEAM pid and reaps all children on its death.
  No app-level work needed.

## Mitigation — existing edge cases

- **muontrap dep kept**: a few ad-hoc callsites still reference
  `MuonTrap.cmd/3` directly (not via `OSProcess`). They will be
  audited in a follow-up; once empty, we'll drop the dep.
- **macOS build**: `exec-port` builds cleanly on darwin 25.2 / clang
  17 with one benign "unused variable" warning upstream in
  `exec_impl.cpp:560`. No entitlements or PTY permissions required.
- **Startup order**: `:erlexec` is listed in `extra_applications`, so
  the `exec` supervisor is up before `Esr.Application.start/2` runs.
  Tests that hit OSProcess directly (`os_process_test.exs`) don't
  need explicit `:exec.start/0`.

## Future

- **Audit muontrap callsites** — remove `:muontrap` dep once
  `Esr.OSProcess` is the only consumer of OS-process wrapping in the
  project.
- **Expose `winsz` / `pty_opts`** — erlexec supports dynamic PTY size
  changes (`:exec.winsz/3`) and termios options. If a future peer
  needs them (e.g. a peer wrapping an interactive shell with resize
  support), thread them through `use Esr.OSProcess`.
- **Reap the old nightly-gate scaffold** — `os_cleanup_test.exs` was
  written assuming we couldn't rely on kernel-level cleanup on SIGKILL.
  With erlexec, the `exec-port` parent-death signaling handles that
  path. The test remains `@tag :skip` (waiting on WS-client helpers)
  but the underlying assumption is stronger now.
- **Closes GitHub issue #7** — the long-standing "should we switch to
  erlexec?" discussion. This is the switch.

## Evidence links

- [`erlexec` README](https://github.com/saleyn/erlexec/blob/master/README.md)
  — PTY, stdin, stop/kill, env options.
- [hex.pm/packages/erlexec](https://hex.pm/packages/erlexec) 2.2.4 — the
  pinned version.
- `runtime/lib/esr/os_process.ex` — the new底座 implementation.
- Commit `P3-17` — the full diff.
- `docs/notes/muontrap-mode3-constraint.md` — the problem this migration
  resolves. Keep for historical context; the empirical finding is still
  correct about MuonTrap, we just no longer care.
- `.claude/skills/muontrap-elixir/SKILL.md` — marked historical as part
  of `P3-17`'s follow-up commit.

---

## Appendix: the MuonTrap Mode 3 Constraint (historical)

Merged in from `muontrap-mode3-constraint.md` (since deleted). Preserved verbatim because it's the empirical foundation for the decision to switch.

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
