# TmuxController — design notes

Target: Elixir 1.19 / OTP 28, `:erlexec ~> 2.2`, tmux in control mode
(`tmux -C new-session -s <name> -c <cwd>`).

This doc explains the three decisions the skill flags as highest-value:
**PTY y/n**, **link y/n**, and **`os_pid` vs `pid`** — plus a few related
choices that fall out of them.

---

## 1. PTY: yes (`:pty` is set)

`tmux -C` is a tmux *client* that speaks the control-mode line protocol
instead of drawing a screen. Internally it still calls `isatty(0)` on
startup. If stdin is a pipe (no PTY), tmux decides it has no terminal and
exits immediately, typically after emitting a single `%exit` line.

Concrete symptom without `:pty`:

```
:exec.run(~c"tmux -C new-session -s foo", [:stdin, :stdout, :monitor])
# → one %exit, then {:DOWN, os_pid, :process, _, {:exit_status, _}}
```

With `:pty` set, erlexec allocates a pseudo-terminal and wires tmux's
stdin/stdout to it. tmux sees a real TTY, stays alive, and the control
protocol flows normally.

The only cost of `:pty` is that output arrives with `\r\n` instead of
`\n`. The parser normalises that with a single
`String.replace(bytes, "\r\n", "\n")` in `normalize_crlf/1` before line
splitting, so the rest of the protocol parser sees clean Unix lines.

No `winsz` / resize is exposed in the public API — control mode doesn't
need a useful size (there's no rendered screen to fit). If the caller
ever wanted to hand the session to a `tmux attach` client, they could
add `:exec.winsz(os_pid, rows, cols)` on top; it's intentionally left off
the default path.

---

## 2. Link: yes (`:exec.run_link/2`, plus `:monitor`, plus `trap_exit`)

The hard requirement from the task is: "guarantee the tmux session dies
when my Elixir supervisor tears down the owning GenServer — including on
BEAM SIGKILL."

`run_link/2` is the only call that gives that guarantee end-to-end:

* **GenServer crash / normal stop** — the link from the GenServer to
  erlexec's internal process triggers a kernel-level shutdown of the
  child tmux. `run/2` (without `_link`) would leave tmux orphaned until
  it exits on its own.
* **BEAM SIGKILL** — erlexec's bundled `exec-port` C++ program is itself
  a direct child of the BEAM. When the BEAM dies (any reason, including
  `kill -9`), the kernel notifies `exec-port`, which then reaps every
  child it started with SIGTERM → `kill_timeout` → SIGKILL. This works
  on macOS too (where Linux-only `PR_SET_PDEATHSIG` doesn't exist)
  because the detection happens at the `exec-port` layer, not at the
  individual child.

We also pass `:monitor` so the GenServer receives
`{:DOWN, os_pid, :process, pid, reason}` when the child exits on its
own (tmux crashed, session killed externally, etc.). With `run_link`
alone we'd get an `{:EXIT, exec_pid, reason}` message via the process
link — `handle_info` covers both shapes, and `Process.flag(:trap_exit, true)`
is set in `init/1` so the link message reaches `handle_info` instead of
killing the GenServer synchronously. That lets us emit a final
`{:exit, reason}` event to the subscriber before stopping.

`terminate/2` additionally:

1. Tries `tmux kill-session` on stdin. This is cosmetic — it lets any
   attached clients see a clean server-side close rather than a hard
   TTY hang-up.
2. Calls `:exec.stop/1` which issues SIGTERM, waits `kill_timeout`
   seconds, then SIGKILL. Wrapped in `try/catch` because the child may
   already be gone.

The `kill_timeout` option is exposed (default 5s) so callers can trade
snappier shutdown against graceful tmux cleanup.

---

## 3. `os_pid` vs Erlang `pid`

erlexec returns `{:ok, exec_pid, os_pid}` from `run_link/2`:

* `exec_pid` — BEAM pid of erlexec's internal process representing the
  child. Only used for pattern-matching `{:EXIT, exec_pid, reason}`
  against our link.
* `os_pid` — kernel PID of the actual tmux process. Every operation on
  the child (except `:exec.ospid/1`) takes this.

The GenServer state stores **both**:

```elixir
%{exec_pid: exec_pid, os_pid: os_pid, ...}
```

and uses them deliberately:

| Operation | Which id | Why |
|---|---|---|
| `:exec.send(os_pid, bytes)` | `os_pid` | erlexec API takes os_pid for I/O |
| `:exec.stop(os_pid)` | `os_pid` | same |
| `:exec.kill(os_pid, sig)` | `os_pid` | same (not used here, but would be) |
| Match `{:stdout, os_pid, bytes}` | `os_pid` | stdout messages are tagged with os_pid |
| Match `{:DOWN, os_pid, :process, _, reason}` | `os_pid` | `:monitor` DOWN messages use os_pid |
| Match `{:EXIT, exec_pid, reason}` | `exec_pid` | link exit uses the BEAM pid |

`os_pid/1` on the public API is the one callback that returns the
kernel PID — useful for the test pattern in the skill
(`ps -p <os_pid>` polling after killing the GenServer) and for anyone
who wants to `kill -INT` the tmux from outside the BEAM.

Guarding the stdout/DOWN clauses with `%{os_pid: os_pid} = state`
prevents late messages from a previous child (if we ever added
re-spawn) from being misrouted.

---

## 4. Other option picks (brief)

* **`:stdin, :stdout, {:stderr, :stdout}`** — tmux control mode is
  line-oriented on stdout and errors are generally empty, but merging
  stderr into stdout means a surprise panic is still captured by our
  line buffer rather than going to the BEAM log unobserved.
* **`{:env, env_to_charlists(env)}`** — skill explicitly warns that
  `{:env, ...}` pairs must be `{charlist, charlist}`; binaries are
  undocumented and fail on some OTP/erlexec combos. Public API accepts
  binaries for ergonomics and converts in `env_to_charlists/1`.
* **Command as a single charlist string** — we build
  `~c"tmux -C new-session -A -s '<sess>' -c '<cwd>'"`. erlexec runs this
  via `/bin/sh -c`, so we `shell_quote/1` the session name and cwd. The
  alternative (argv list) is nicer for untrusted input but overkill here
  and makes the command harder to read in logs.
* **`-A`** — tmux's "attach-or-create". Lets the same GenServer reattach
  to a surviving session after a BEAM restart in environments where
  tmux isn't cleaned up. Doesn't affect the single-run lifecycle that
  the task asks for, and `run_link` still cleans up on BEAM death —
  `-A` is purely upward-compatible with reconnection stories.

## 5. Output framing & protocol parsing

The skill warns that erlexec delivers arbitrary stdout chunks (no
built-in `{:line, N}` framing). The controller keeps a `buffer` field in
state, CRLF-normalises each chunk, splits on `\n`, and carries any
trailing partial line forward.

Each full line goes through a small tmux control-mode parser:

* `%begin N T F` → push a pending frame, emit `{:begin, N, T, F}`.
* non-`%` lines inside a pending frame → accumulated as payload.
* `%end N T F` / `%error N T F` → pop frame, emit
  `{:end | :error, N, T, F, payload}`.
* `%output %<pane> <data>` → decode `\nnn` octal escapes, emit
  `{:output, pane, data}`.
* `%exit [reason]` → emit `{:exit, reason}`.
* Any other `%foo a b c` → emit `{:notification, "foo", [a,b,c]}`
  (covers `session-changed`, `window-add`, `client-detached`, etc.).
* Fallthrough → `{:raw, line}` so nothing is silently dropped.

Events are delivered as `{:tmux_event, ref, event}` to the subscriber
pid; the ref is handed out on `{:tmux_ready, ref, os_pid}` right after
`init/1` succeeds, so the subscriber can pattern-match without caring
about GenServer identity.

---

## 6. What's intentionally NOT done

* **Response correlation.** The parser surfaces `%begin`/`%end` pairs
  with their command number, but doesn't match them back to outgoing
  `send_command/2` calls. A request/reply layer (a map of
  `number → from`) is a clean wrapper to build on top, but it's out of
  scope for "wrap the control-mode process" and would force a
  synchronous API that hides the event stream.
* **`Process.monitor` on the subscriber.** The subscriber is usually
  the owning LiveView / test / supervisor and is expected to outlive the
  controller. Monitoring it would add complexity (what do we do if the
  subscriber dies? re-resolve? stop?) without a clear winning answer
  for this layer.
* **Restart logic.** Belongs in the supervisor, not here. This module
  crashes cleanly on child death with `{:child_exited, reason}`; the
  supervisor's restart strategy decides what to do next.
