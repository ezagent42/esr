# Gracefully stopping an erlexec child (SIGTERM → wait → SIGKILL)

## Short answer

Use `:exec.stop/1` — it already implements the exact "SIGTERM, wait, then SIGKILL" pattern you described. Control the wait window with the `{:kill_timeout, seconds}` option at spawn time.

```elixir
{:ok, pid, os_pid} = :exec.run_link(~c"/path/to/child", [
  :stdin, :stdout, :monitor,
  {:kill_timeout, 5}        # 5 seconds between SIGTERM and SIGKILL (default: 5)
])

# ... later, to gracefully shut it down:
:exec.stop(os_pid)
```

That single call sends SIGTERM, waits `kill_timeout` seconds, and sends SIGKILL if the child has not exited. You do not have to implement the timer yourself.

## Which identifier do I pass?

**`os_pid` — the integer OS PID, NOT the Erlang `pid`.**

`run_link/2` returns `{:ok, pid, os_pid}`:

| Return value | Type | Use for |
|---|---|---|
| `pid` | Erlang `pid()` (BEAM GenServer) | links, `Process.monitor/1`, `:exec.ospid(pid)` |
| `os_pid` | `integer()` (kernel PID) | **every** `:exec.*` call below |

```elixir
# Correct
:exec.stop(os_pid)
:exec.kill(os_pid, 15)          # SIGTERM by signum
:exec.kill(os_pid, 9)           # SIGKILL by signum
:exec.send(os_pid, "data\n")

# Wrong — passing the Erlang pid will raise / mis-dispatch
:exec.stop(pid)                 # DON'T
```

The only `:exec.*` function that takes the Erlang `pid` is the converter `:exec.ospid(pid)`.

## Manual variant (if you really want to roll your own timing)

You don't need this — `:exec.stop/1` is the idiomatic API — but for completeness:

```elixir
:exec.kill(os_pid, 15)          # SIGTERM
receive do
  {:DOWN, ^os_pid, :process, _, _} -> :ok    # requires :monitor at spawn
after
  5_000 -> :exec.kill(os_pid, 9)             # SIGKILL after 5s
end
```

This only works if you passed `:monitor` (or used `run_link`) at spawn time. Otherwise you won't receive an exit notification and you'll always fall through to SIGKILL.

## Gotchas

1. **`os_pid` vs `pid`.** The #1 bug. `:exec.stop/1` and `:exec.kill/2` both take `os_pid`. If you pass the Erlang pid you'll get a crash, not silent success.

2. **`{:kill_timeout, N}` is set at spawn time, not at stop time.** You can't change it per-stop call. Default is 5 seconds. If you want "give it 10s to clean up," spawn with `{:kill_timeout, 10}`.

3. **`:exec.stop/1` returns quickly** — it does not block for `kill_timeout`. The timeout enforcement happens inside the `exec-port` helper process. If you need to block until the child is actually gone, you need `:monitor` (or the `run_link` exit message) and a `receive`.

4. **`run_link` does not obviate `:exec.stop`** when you want a *graceful* shutdown. The link only guarantees kernel-level cleanup when the owning process dies; it will SIGKILL by default if the child is still alive at BEAM exit. If the child has state to flush (e.g. tmux `kill-session`, closing files), call `:exec.stop(os_pid)` in your GenServer's `terminate/2` callback so it gets SIGTERM first.

5. **`:exec.kill(os_pid, 15)` alone will not escalate to SIGKILL.** It sends one signal and returns. If you want "SIGTERM-then-SIGKILL" semantics, use `:exec.stop/1` (which does the escalation for you) or implement the timer yourself. Don't assume `:exec.kill` escalates.

6. **SIGKILL cannot be caught.** Once the `kill_timeout` elapses, the child is gone with no chance to clean up. Set `kill_timeout` to a value that matches your child's worst-case graceful-shutdown latency.

7. **Process groups.** By default erlexec sends the signal to the immediate child. If your child spawns its own grandchildren (shells, tmux servers), they may survive unless the child forwards the signal or you spawned with process-group semantics. `:exec.stop` generally handles the default case; for exotic trees, inspect `:exec.run/2` options or rely on `exec-port`'s BEAM-exit reaping.

## TL;DR recipe

```elixir
# Spawn
{:ok, _pid, os_pid} = :exec.run_link(cmd, [
  :stdin, :stdout, :monitor,
  {:kill_timeout, 5}
])

# Graceful stop — SIGTERM, wait 5s, SIGKILL (all handled by erlexec)
:exec.stop(os_pid)
```

Pass `os_pid` (the integer), not `pid` (the Erlang pid).
