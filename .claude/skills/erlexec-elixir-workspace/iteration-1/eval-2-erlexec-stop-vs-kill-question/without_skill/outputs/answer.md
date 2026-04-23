# Gracefully stopping an erlexec child process

## Short answer

Use `:exec.stop/1` with the **OS pid** (the integer returned as `{:ok, _erl_pid, os_pid}` from `:exec.run_link/2`). It performs the "SIGTERM, wait, then SIGKILL" dance for you automatically — you do not have to implement it yourself.

If you want explicit control over the grace period, use the `{:kill_timeout, Seconds}` option when starting the process, or send `:sigterm` with `:exec.kill/2` yourself and fall back to `:sigkill` on timeout.

---

## The exact API calls

### 1. Start the process and capture the OS pid

```elixir
{:ok, erl_pid, os_pid} =
  :exec.run_link(~c"your-command --args",
    [
      :stdout,
      :stderr,
      {:kill_timeout, 5}   # seconds between SIGTERM and SIGKILL (default: 5)
    ])
```

- `erl_pid` is the Erlang supervising process (a real BEAM pid).
- `os_pid` is the integer OS-level pid of the child.
- Because you used `run_link`, the BEAM process is linked — if your caller dies, erlexec will clean the child up for you.

### 2. Graceful stop (recommended)

```elixir
:exec.stop(os_pid)          # pass the OS pid (integer)
# or equivalently:
:exec.stop(erl_pid)         # pass the Erlang pid
```

`:exec.stop/1` accepts **either** the OS pid or the Erlang pid — the library resolves it internally. It sends `SIGTERM`, waits up to `:kill_timeout` seconds, then escalates to `SIGKILL` if the child hasn't exited. This is exactly the behaviour you described.

There is also `:exec.stop_and_wait(Pid, Timeout)` which blocks until the child is fully reaped and returns `:ok` or `{:error, reason}` — handy in tests.

### 3. Manual SIGTERM-then-SIGKILL (if you want explicit control)

```elixir
:exec.kill(os_pid, :sigterm)   # first signal (15)

# in the caller, wait for the {:EXIT, _, _} / {:DOWN, ...} message, e.g.:
receive do
  {:EXIT, ^erl_pid, _reason} -> :ok
after
  3_000 ->
    :exec.kill(os_pid, :sigkill)   # signal 9 — unignorable
end
```

`:exec.kill/2` accepts either the OS pid or the Erlang pid, and the signal as an atom (`:sigterm`, `:sigkill`, `:sigint`, `:sighup`, ...) or integer.

---

## Which identifier to pass?

Both `:exec.stop/1` and `:exec.kill/2` accept either:

| You have            | It works because…                                                                |
|---------------------|----------------------------------------------------------------------------------|
| `os_pid` (integer)  | erlexec looks up the owning BEAM process in its internal table.                  |
| `erl_pid` (pid)     | erlexec looks up the OS pid it manages for that BEAM process.                    |

Prefer the **OS pid** when you've stored it for later shutdown (it's a plain integer and easier to serialize / log). Prefer the **Erlang pid** when you already have it from `run_link` and want the benefit of link/monitor semantics in the same breath.

Do **not** call `Process.exit(erl_pid, :kill)` or `:erlang.exit/2` to stop the child — that kills the BEAM-side supervisor process, not the OS process. The OS child may be left orphaned (though the erlexec port owner will usually still reap it, this is not guaranteed and the semantics are ugly).

---

## Gotchas

1. **`run_link` vs `run`.** With `run_link/2`, if your calling process dies, erlexec terminates the child using the same kill_timeout mechanism. With `run/2` you must stop it yourself, or the OS process lives on until erlexec's port owner exits.

2. **`:kill_timeout` is in seconds, not milliseconds.** Easy to fat-finger. Default is 5.

3. **Custom kill command.** If your process catches SIGTERM and needs a custom shutdown signal (e.g. `kill -USR1`, or `my-cli shutdown --graceful`), pass `{:kill, ~c"kill -USR1"}` as a start option. erlexec will run that command instead of sending SIGTERM, then fall back to SIGKILL after `:kill_timeout`.

4. **Process groups.** By default, erlexec starts the child in its own process group (`setpgid`). This means SIGTERM/SIGKILL reaches the whole group — usually what you want, but surprising if your child spawns its own children and you expected only the top process to die. If you need only the leader, start with `{:kill_group, false}` (and make peace with potential zombies).

5. **`:stop` is asynchronous.** It returns `:ok` immediately after requesting shutdown; the child may still be alive for up to `:kill_timeout` seconds. Use `:exec.stop_and_wait/2` or monitor/link the `erl_pid` if you need to block until it's really gone.

6. **Exit reason after SIGKILL.** Expect `{:exit_status, 9}` or `{:exit_status, 137}` style reasons (signal-shifted). A graceful SIGTERM exit usually shows up as `:normal` or `{:exit_status, 0}` if the child handled it and exited cleanly.

7. **Don't call `:exec.kill(os_pid, 0)` expecting a no-op probe.** erlexec does support signal 0 (existence check), but the return convention is different from POSIX `kill(2)`; use `:exec.status/1` or `:exec.ospid/1` if you just want to check liveness.

---

## TL;DR pattern for your use case

```elixir
{:ok, pid, os_pid} =
  :exec.run_link(~c"./my-child", [:stdout, {:kill_timeout, 3}])

# …later, when you want to stop it:
:ok = :exec.stop(os_pid)   # SIGTERM, wait 3s, then SIGKILL — done.
```

That's it. You almost never need to hand-roll the escalation — let `:kill_timeout` + `:exec.stop/1` do it.
