# Approach: Python Sidecar via erlexec (line-delimited JSON)

## Goal

Wrap `python -m my_app.voice_asr` from Elixir so we can:

1. Send line-delimited JSON requests to its **stdin**.
2. Receive line-delimited JSON replies from its **stdout**.
3. Guarantee the Python process dies when the owning Elixir GenServer exits — including when the BEAM itself is SIGKILLed.

## Why erlexec (not `Port`)

A plain Erlang `Port` does **not** guarantee OS-level reaping of the child when the BEAM crashes or is `kill -9`'d. Ports only close their file descriptors; the child may survive as an orphan attached to PID 1.

`erlexec` solves this by running a small C helper (`exec-port`) as the **parent** of every spawned child. `exec-port`:

- Receives a list of "children to kill" over a pipe from the BEAM.
- When the BEAM vanishes (pipe EOF, even on SIGKILL), it iterates its child table and sends each one SIGTERM, then SIGKILL after `kill_timeout`.
- Child processes are group-leader-isolated so a single `killpg` cleans up Python's subprocesses too.

This is the load-bearing reason to use erlexec here. Everything else (stdin/stdout framing) could be done with a Port.

## Design

- One `GenServer` per sidecar instance. `start_link/1` launches the child with `:exec.run_link/2`.
- `:exec.run_link/2` options we rely on:
  - `:stdin` — write to the child's stdin via `:exec.send/2`.
  - `:stdout`, `:stderr` — get `{:stdout, os_pid, data}` and `{:stderr, os_pid, data}` messages.
  - `:monitor` — deliver `{:DOWN, os_pid, :process, pid, reason}` when the child exits.
  - `{:kill_timeout, N}` — how many seconds `exec-port` waits after SIGTERM before SIGKILL. We derive it from `:stop_grace_ms`.
- **Framing**: erlexec hands us arbitrary chunks on stdout, not lines. We keep a `stdout_buf` binary and `:binary.split(buf, "\n", [:global])` on every chunk, dispatching complete lines and keeping the trailing partial line for next time. Same treatment for stderr (logged only).
- **Request/response correlation**: requests are placed in a FIFO queue of `from` tags. When a complete JSON line arrives from stdout we `:queue.out` the oldest caller and `GenServer.reply/2`. This assumes the sidecar replies once per request in submission order — the standard convention for line-delimited JSON sidecars. If the sidecar emits unsolicited events, they arrive when the queue is empty and are logged (real deployments would forward to a subscriber or PubSub topic).
- **Encoding**: `Jason.encode!(payload) <> "\n"` into stdin. Any payload that fails to encode is rejected synchronously with `{:error, {:encode_failed, _}}` without enqueuing.

## Lifecycle guarantees

| Scenario | What happens |
|---|---|
| `GenServer.stop/1` (normal) | `terminate/2` sends `:eof` to close stdin, then `:exec.stop/1` which escalates SIGTERM → SIGKILL using `kill_timeout`. |
| Supervisor restart / `:EXIT` | `trap_exit` + `terminate/2` same as above. |
| GenServer crashes | `:exec.run_link/2` linked the exec pid to the GenServer; its death triggers exec-port to reap the child. |
| BEAM crashes (`SIGSEGV`) | The pipe to `exec-port` closes; `exec-port` sees EOF and kills every tracked child. |
| `kill -9` on the BEAM | Same as above — `exec-port` is a separate OS process; it survives, detects pipe EOF, and kills children. |
| Python ignores SIGTERM | `kill_timeout` (default 2s in our config) elapses, `exec-port` sends SIGKILL. |

## Caveats and design choices

- **No pty**: we deliberately do not use `:pty` / `:pty_echo`. Line-delimited JSON wants raw pipe semantics; a pty can inject CR/LF translation and echo artifacts.
- **Python line buffering**: the caller should run Python with `-u` or `PYTHONUNBUFFERED=1` so stdout is not block-buffered. Consider making the default command `["python", "-u", "-m", "my_app.voice_asr"]` in production.
- **Back-pressure**: `:exec.send/2` is asynchronous; there is no flow control from the child. If the sidecar is slow and callers flood requests, the `pending` queue grows without bound. For production, add a `max_inflight` guard and reject or backpressure.
- **Ordering assumption**: if the sidecar can reply out of order, add an `id` field to each request and match by id instead of FIFO. The module's `call/3` is easy to extend with a `%{pending_by_id: %{}}` map.
- **Restart policy**: not implemented here — put this GenServer under a `Supervisor` with `restart: :transient` (or `:permanent` if the sidecar is a singleton), and set `:max_restarts` to avoid thrash if Python crashes on start.
- **stderr**: captured and logged at `:warn` line-by-line. Swap to structured logging if the Python side emits JSON on stderr too.

## Testing hints

- Use a trivial `fake_sidecar.py` that echoes each JSON line with `{"echo": ...}` to exercise encode/decode/framing without heavyweight ASR.
- To verify BEAM-kill reaping: start the sidecar, `kill -9 $(pgrep beam.smp)` in another shell, then confirm the Python PID is gone within `kill_timeout + ~200ms`.
- To verify partial-line framing: have the fake sidecar write one character at a time with `sys.stdout.write(...); sys.stdout.flush()` — the GenServer must still deliver complete JSON objects only.
