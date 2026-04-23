# approach — `VoiceAsrSidecar`

Wrap `python -m my_app.voice_asr` in an Elixir GenServer that speaks
line-delimited JSON in both directions and dies cleanly when its owner dies.
Built on erlexec `~> 2.2`, following the ESR `erlexec-elixir` skill guidance.

## Requirements recap

1. Send line-delimited JSON requests to the child's stdin.
2. Receive line-delimited JSON replies from the child's stdout and hand them
   to a subscriber pid.
3. When the GenServer exits — normal shutdown, crash, or SIGKILL of the whole
   BEAM — the python process must die too, with no orphans.

## Key decisions and why

### 1. `:exec.run_link/2`, not `:exec.run/2`

The sidecar's lifetime is bound to this GenServer (peer-like). `run_link`
creates a BEAM-side link so:

* If the GenServer crashes, erlexec tears down the child (SIGTERM →
  `kill_timeout` → SIGKILL).
* If the BEAM is SIGKILL-ed, the bundled `exec-port` C++ helper notices the
  parent death and reaps every child it spawned. This works on macOS too,
  where `PR_SET_PDEATHSIG` is unavailable.

`run/2` would orphan the child on GenServer crash until the BEAM itself
exits — the wrong semantics for a managed peer.

### 2. No `:pty`

The protocol is line-oriented JSON over pipes; the sidecar does not call
`isatty()` or otherwise require a terminal. Allocating a PTY would:

* Translate newlines to CRLF on stdout (forcing extra trim logic).
* Introduce line-discipline buffering and echo concerns.
* Cost a file descriptor pair per peer.

Plain pipes are correct. The only Python-side gotcha is block-buffering of
stdout when it is not a TTY, which we fix with `PYTHONUNBUFFERED=1` in the
child env. (If the sidecar ever calls `print(...)` without `flush=True`, the
env var is what keeps replies flowing.)

### 3. Options set on `run_link`

```elixir
[
  :stdin,                    # enables :exec.send/2
  :stdout,                   # delivers {:stdout, os_pid, bytes}
  {:stderr, :stdout},        # merge stderr for single-stream logging
  :monitor,                  # deliver {:DOWN, os_pid, :process, _, reason}
  {:kill_timeout, 5},        # SIGTERM → 5s → SIGKILL
  {:env, [{~c"PYTHONUNBUFFERED", ~c"1"} | user_env_as_charlists]}
]
```

Every entry in `{:env, ...}` is a `{charlist, charlist}` pair — per the
skill, binaries here are undocumented and fail on some OTP/erlexec
combinations.

### 4. `os_pid` vs `pid`

The skill calls this out as the #1 source of bugs. The module stores both
values returned by `run_link` (`exec_pid`, `os_pid`) but passes `os_pid` to
every `:exec.*` call (`send`, `stop`). The Erlang `exec_pid` is only used to
recognize its `{:EXIT, _, _}` message so we can ignore it (the `:DOWN`
message is the authoritative exit notification).

### 5. Line framing done manually

erlexec does not provide `{:line, N}` framing. Stdout arrives as arbitrary
chunks. The state carries a `buffer` string, and every incoming `{:stdout,
_, bytes}` runs through `split_lines/1`, which yields complete lines plus a
(possibly empty) trailing remainder. Complete lines are JSON-decoded and
forwarded to the subscriber as `{:asr_reply, map}`. Malformed lines are
logged and dropped so one bad frame doesn't poison the stream.

Trailing `\r` is stripped defensively — cheap insurance if the sidecar ever
gets wrapped in a PTY later.

### 6. `send_request/2` writes JSON + `\n`

`:exec.send(os_pid, [json, ?\n])` uses iodata — no intermediate binary
concat, and the newline is appended atomically with the payload so the child
never sees a half-line.

### 7. Exit handling

* `{:DOWN, os_pid, :process, _, reason}` → `{:stop, reason}` so supervisors
  see the child's exit status. `:normal` and `{:exit_status, 0}` are
  normalized to `:normal`.
* `{:EXIT, exec_pid, _}` from the link is swallowed (the `:DOWN` message has
  the info we need).
* `terminate/2` calls `:exec.stop(os_pid)` as a best-effort graceful
  shutdown. `run_link` already guarantees eventual reaping, but `stop`
  speeds it up and gives the child a chance to flush on SIGTERM before the
  SIGKILL after `kill_timeout`.

### 8. `:exec.start/0` is idempotent

Called from `init/1` so the module works whether or not the application has
added `:erlexec` to `extra_applications`. `{:error, {:already_started, _}}`
is treated as success, per the skill.

## What the caller sees

```elixir
{:ok, pid} = VoiceAsrSidecar.start_link(
  subscriber: self(),
  python: "./.venv/bin/python",
  module: "my_app.voice_asr",
  env: [{"LOG_LEVEL", "info"}]
)

VoiceAsrSidecar.send_request(pid, %{"op" => "recognize", "audio_b64" => "..."})

receive do
  {:asr_reply, %{"text" => text}} -> IO.puts(text)
end
```

## Cleanup invariant test (per the skill)

```elixir
Process.flag(:trap_exit, true)
{:ok, pid} = VoiceAsrSidecar.start_link([])
{:ok, os_pid} = VoiceAsrSidecar.os_pid(pid)

Process.exit(pid, :kill)
assert_receive {:EXIT, ^pid, :killed}, 1_000

# Poll `ps -p <os_pid>` up to 10s; erlexec's SIGTERM → kill_timeout → SIGKILL
# must have reaped the child by then.
```

## Dependencies the module assumes

```elixir
# mix.exs
{:erlexec, "~> 2.2"},
{:jason, "~> 1.4"}

def application, do: [extra_applications: [:logger, :erlexec]]
```

`:erlexec` in `extra_applications` is nice-to-have (OTP starts it); the
idempotent `:exec.start()` in `init/1` also covers the case where it is not
listed.
