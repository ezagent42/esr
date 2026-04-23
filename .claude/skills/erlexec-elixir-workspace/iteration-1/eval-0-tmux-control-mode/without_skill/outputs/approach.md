# Approach: `TmuxController` GenServer

## Problem

Wrap a `tmux -C new-session` process inside a GenServer so that:

1. We can write control-protocol commands to its stdin.
2. We can parse the line-oriented control-mode events arriving on stdout
   (`%begin` / `%end` / `%error` / `%output` / `%exit` / notifications).
3. The tmux session is guaranteed to die when the BEAM goes away — **even
   on `SIGKILL`**, where `terminate/2` never runs and normal Port ownership
   gives no promises.

Target: Elixir 1.19 / OTP 28, with `:erlexec` `~> 2.2` available.

## Why `:erlexec` rather than `Port.open/2`

Raw Erlang ports only clean up their OS child when the **port itself** is
closed by the VM. On `SIGKILL` the VM evaporates without closing ports,
leaving orphan tmux servers behind.

`:erlexec` solves this by spawning a small C supervisor (`exec-port`) and
communicating with it over a pipe. All OS children are owned by that
supervisor, which detects EOF on its stdin pipe (exactly what happens when
the BEAM is killed) and reaps every tracked child before exiting. That is
the only reliable mechanism on POSIX short of cgroups/PID namespaces.

We additionally pass:

- `:monitor` — the GenServer gets a `{:DOWN, os_pid, :process, _, reason}`
  message when tmux exits, so we can surface `%exit` reliably.
- `{:kill_timeout, N}` — SIGTERM first, then SIGKILL after `N` seconds.
- `{:kill, "kill -KILL $CHILD_PID"}` — belt-and-braces explicit kill
  command, in case tmux ignores SIGTERM (it generally respects it).
- `:exec.run_link` — links the exec-pid to the GenServer so a crash in
  either direction tears the pair down.

## Spawning tmux

```
tmux -C new-session -A -s <session> -c <cwd>
```

- `-C` puts tmux into control mode (line-oriented, no escape sequences).
- `-A` attaches if the session already exists, otherwise creates it
  (idempotent for supervisor restarts; drop it if you always want a fresh
  session).
- `TMUX` env var is unset so we don't accidentally inherit a parent tmux
  and fail with "sessions should be nested with care".

## Stdout parsing (control-mode FSM)

Control-mode output is strictly line-based (`\n`-separated, no CRLF).
Every command submitted on stdin is acknowledged by:

```
%begin  <time> <number> <flags>
  ...response lines...
%end    <time> <number> <flags>
```

Errors look identical except the opener is `%error` (still closed by
`%end`). Everything else is a notification:

- `%output %<pane-id> <octal-escaped data>` — byte stream from a pane.
- `%exit [reason]` — tmux is shutting down.
- `%session-changed`, `%window-add`, `%unlinked-window-add`,
  `%layout-change`, etc.

The parser is a two-state FSM:

- `:idle` — a `%` line either opens a block (`%begin`/`%error`) or is a
  standalone notification.
- `{:in_block, kind, number, acc}` — collect lines until we hit
  `%end <...> <number> <...>` that matches.

Command correlation: we maintain a FIFO queue of `{from, cmd}` tuples for
outstanding synchronous callers. When a `%begin` arrives we pop the head
of the queue and store `{from, cmd}` in a map keyed by the tmux-assigned
`<number>`. On `%end`/`%error` we look up by number and `GenServer.reply/2`.
This is robust against out-of-order resolution (tmux can technically
interleave blocks if commands are pipelined; using the number rather than
FIFO position keeps us correct).

`%output` payloads are decoded: tmux octal-escapes non-printable bytes and
backslashes as `\\ooo`. We do the inverse transformation before handing
the data to the subscriber.

## Public API

```elixir
TmuxController.start_link(session: "s", cwd: "/tmp", subscriber: self())
TmuxController.command(pid, "list-windows")   # => {:ok, [lines]} | {:error, [lines]}
TmuxController.send(pid, "kill-window -t 0")  # fire-and-forget
TmuxController.stop(pid)
```

Subscriber receives:

- `{:tmux, {:output, pane, binary}}`
- `{:tmux, {:notification, line}}`
- `{:tmux, {:exit, reason}}`

## Shutdown sequence

`terminate/2`:

1. Write `kill-session\n` on stdin — tmux exits cleanly, dropping the
   session.
2. Call `:exec.stop_and_wait/2` which sends SIGTERM, waits `kill_timeout`,
   escalates to SIGKILL, and blocks until the child is reaped.

If the BEAM itself is SIGKILL'd, `terminate/2` does not run, but
`exec-port` observes the stdin-pipe EOF and performs the same SIGTERM→
SIGKILL escalation on every managed child. That is the guarantee the
problem statement asks for.

## Notes / trade-offs

- We `trap_exit` so that `:exec.run_link` EXIT signals arrive as messages
  instead of killing us. If you prefer "let the supervisor restart us",
  drop the `Process.flag(:trap_exit, true)` and remove the `:EXIT` clause.
- `kill_timeout` defaults to 5 s. Lower it if you want aggressive kills.
- For high-throughput stdout you may want to set `:stdout` to `:raw` and
  process in larger chunks; the current implementation buffers partial
  lines correctly either way.
- The parser does not interpret `%output` as UTF-8 — it returns raw
  bytes, because tmux panes are terminal streams and may contain any
  encoding. Upgrade to `String.valid?/1` checks in the subscriber if
  needed.
