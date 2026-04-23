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
