---
name: muontrap-elixir
description: Use whenever the task involves the MuonTrap Elixir package (1.7.x) — wrapping OS processes with guaranteed cleanup on BEAM exit, spawning tmux / python / shell / any long-running external program under OTP supervision, designing interactive sidecar peers with stdin+stdout, or debugging orphaned processes. Triggers include any code that touches `:muontrap`, `MuonTrap.cmd`, `MuonTrap.Daemon`, `MuonTrap.muontrap_path`, `Port.open` against an OS-spawned child, writing a custom OSProcess底座, reasoning about "Mode 3" stdin/stdout/cleanup trade-offs, deciding between the muontrap wrapper and plain Port for interactive children, or reviewing peer code that spawns external commands. Also use when touching the ESR `Esr.OSProcess` / `Esr.TmuxProcess` / `Esr.PyProcess` modules — they're direct consumers of these patterns. ALWAYS use even when MuonTrap is mentioned briefly — training data doesn't cover 1.7 API reliably and the library has a non-obvious empirical constraint (Mode 3 stdin+stdout+cleanup cannot be satisfied simultaneously — see the body) that is easy to get wrong.
---

# MuonTrap (Elixir) — OS Process Wrapping with Guaranteed Cleanup

MuonTrap is the canonical Elixir library for running external OS processes with the guarantee that they die when the BEAM process that started them dies. It's the standard choice when you care about cleanup — Elixir's native `Port` does NOT guarantee this on macOS or many Linux configurations (the child can outlive the BEAM on SIGKILL).

**Target version: 1.7.x** (pinned in ESR's `mix.exs`). Hex: `{:muontrap, "~> 1.7"}`.

This skill's goal: prevent the two most common failure modes observed in 2025-2026 LLM-written MuonTrap code —
1. Inventing APIs that don't exist (e.g. `MuonTrap.Daemon.send/2`, a stdin write method).
2. Using `:code.priv_dir(:muontrap)` / `Path.join` to locate the binary instead of the documented helper.

---

## 🛑 Before you write any MuonTrap code

1. **Run Context7 query** — `/fhunleth/muontrap` — with the specific topic you need (stdin, cleanup, pool, etc). The docs change between 1.5 / 1.6 / 1.7; do not rely on memory.
2. **Decide which of the three usage modes fits your task** — pick exactly one. They are not interchangeable. See "Three modes" below.
3. **If your task involves writing to the child's stdin, you CANNOT use `MuonTrap.Daemon`.** Stdin is not exposed. Jump to "Mode 3: Port + muontrap binary" immediately.

---

## Three modes (pick one)

### Mode 1: `MuonTrap.cmd/3` — one-shot command

Blocking wrapper around `System.cmd/3`. The child is killed when the caller GenServer dies. Use when:
- The child is short-lived.
- You don't need streaming interaction (stdout can be buffered into a collector).
- No stdin writes after start.

```elixir
{output, 0} = MuonTrap.cmd("git", ["status"], [])

# With stdout streaming
MuonTrap.cmd("ping", ["-c", "3", "localhost"],
  into: IO.binstream(:stdio, :line))

# With shutdown grace period
MuonTrap.cmd("slow_service", [],
  delay_to_sigkill: 2000)  # SIGTERM, wait 2s, then SIGKILL

# With env + uid
MuonTrap.cmd("echo", [], env: [{"VAR", "val"}], uid: "nobody")
```

Returns `{output_collected, exit_status}`. Zero stdin API. Blocks the caller.

### Mode 2: `MuonTrap.Daemon` — long-running supervised child

A GenServer that owns a long-running external command. Add to supervision tree. The OS process is killed when the Daemon GenServer terminates (normal exit, crash, BEAM shutdown — all covered).

```elixir
children = [
  {MuonTrap.Daemon, ["redis-server", ["--port", "6380"],
   [name: :my_redis, log_output: :info]]}
]

# Programmatic
{:ok, pid} = MuonTrap.Daemon.start_link("cmd", ["arg"], name: :my_daemon)
os_pid = MuonTrap.Daemon.os_pid(:my_daemon)
stats = MuonTrap.Daemon.statistics(:my_daemon)  # {cpu, mem, ...}
```

**Limitations:**
- **No stdin API.** You cannot `MuonTrap.Daemon.send/2` (does not exist). You cannot write bytes to the child's stdin.
- Stdout/stderr are consumed by the Daemon's internal port handler and can be forwarded to Logger (`log_output: :info`) or discarded. You can't hook them into custom callback dispatch.

Use Mode 2 for: pure-output daemons (redis, nginx, a database, a background worker that logs).

### Mode 3: interactive sidecar (stdin + stdout) — pick your sub-variant

**STOP and pick 3a / 3b / 3c based on what you actually need.** Mode 3 has a hard empirical constraint discovered in ESR PR-1 (see `docs/notes/muontrap-mode3-constraint.md` in the ESR repo): **MuonTrap 1.7's wrapper binary cannot simultaneously provide all three of — stdin write from Elixir, stdout read in Elixir, and BEAM-exit cleanup of the child.** Without `--capture-output`, child stdout is `dup2`'d to `/dev/null`. With `--capture-output`, the wrapper consumes its own stdin as an ack-byte-counting channel, so `Port.command/2` bytes never reach the child. Pick any two.

#### Mode 3a: cleanup + stdout (no stdin)

For daemons you launch and observe — the child produces output, Elixir watches, Elixir never needs to write back.

Use `MuonTrap.Daemon` with `log_output: :info` or `{:stdout, pid}`-style forwarding (see `MuonTrap.Daemon` options). `MuonTrap.Daemon` already encodes this sub-variant; you don't need to DIY a Port.

```elixir
{:ok, daemon} = MuonTrap.Daemon.start_link("watcher", ["--verbose"],
  log_output: :info, name: :my_watcher)
# Daemon handles SIGTERM-→-SIGKILL cleanup on BEAM exit.
# No stdin access is available; don't try to use GenServer.call/cast to write bytes.
```

#### Mode 3b: cleanup + stdin (stdout silently discarded)

For fire-and-forget processes that need a kick-off command and then run autonomously.

This is the rarest of the three. Use `MuonTrap.cmd/3` with `into: IO.stream(:stdio, :line)` to discard output, and pipe stdin at spawn time via `stderr_to_stdout`. In practice, you almost always want 3a or 3c instead — if you have a case that truly needs 3b, come back and expand this section.

#### Mode 3c: stdin + stdout, no wrapper (DIY cleanup)

For interactive sidecars where you exchange data with the child across its whole lifetime: tmux in control mode, Python JSON-line RPC, interactive shells.

**Do NOT use the muontrap wrapper binary for this case.** Use a plain Elixir `Port` directly. Cleanup becomes the child's own responsibility — the two reliable patterns:

1. **Child detects stdin EOF** (standard for well-behaved Python scripts, shell REPLs): when BEAM closes the Port, the child's stdin hits EOF, and it exits on its next read. Clean, fast (~100ms for Python with `PYTHONUNBUFFERED=1`). No Elixir-side code needed.
2. **Child has an out-of-band cleanup command**: e.g. `tmux kill-session -t <name>`. Fire it in the Peer's `terminate/2`. Supervisor teardown guarantees `terminate/2` runs (unless the BEAM itself is SIGKILL'd, in which case the child's session may outlive — accept that trade-off per-peer-type).

**Code template (Mode 3c):**

```elixir
defmodule MyInteractive do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def write(pid, bytes), do: GenServer.cast(pid, {:write, bytes})

  @impl true
  def init(opts) do
    exe = Keyword.fetch!(opts, :exe)      # e.g. "tmux"
    args = Keyword.get(opts, :args, [])   # e.g. ["-C", "new-session", "-s", name]
    env = Keyword.get(opts, :env, [])

    # Plain Port — NO muontrap wrapper.
    # Spawn the target command directly. Cleanup must be handled
    # by the child itself (EOF-on-stdin) or by terminate/2 below.
    port =
      Port.open(
        {:spawn_executable, System.find_executable(exe)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 4096},
          {:env, to_env_charlists(env)},
          {:args, args}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {:ok, %{port: port, os_pid: os_pid, exe: exe, args: args,
            subscriber: opts[:subscriber] || self()}}
  end

  @impl true
  def handle_cast({:write, bytes}, s) do
    true = Port.command(s.port, bytes)
    {:noreply, s}
  end

  @impl true
  def handle_info({port, {:data, {_eol_flag, line}}}, %{port: port} = s) do
    send(s.subscriber, {:child_line, line})
    {:noreply, s}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    {:stop, {:child_exited, status}, s}
  end

  @impl true
  def terminate(_reason, s) do
    # Per-peer cleanup. Examples:
    # - tmux: System.cmd("tmux", ["kill-session", "-t", s.session_name])
    # - python: nothing — child exits on stdin EOF when Port dies
    :ok
  end

  defp to_env_charlists(env) do
    for {k, v} <- env, do: {String.to_charlist(k), String.to_charlist(v)}
  end
end
```

**When Mode 3c is NOT enough** (BEAM hard-crashes + child doesn't detect EOF + there's no out-of-band kill command):
- Consider `erlexec` (see [GitHub issue #7](https://github.com/ezagent42/esr/issues/7) in ESR) — more sophisticated OS-process management with full stdin/stdout/cleanup support in one package.
- Or run a thin wrapper script (bash / python) that reads from its own stdin, pipes to the real child, and kills the child when stdin closes. More code, but gives you 3-way properties via composition.

**Why plain Port + muontrap wrapper breaks (the empirical finding):**
- Plain Port **without** muontrap: relies on child EOF-on-stdin detection. Works for tmux and Python; doesn't work for children that ignore stdin.
- `muontrap` wrapper binary receives signals and explicitly kills the child on parent death (via prctl `PR_SET_PDEATHSIG` on Linux, `kqueue EVFILT_PROC EV_NOTE_EXIT` on macOS). Cleanup is guaranteed even on abnormal termination.

---

## Binary wrapper CLI reference

`MuonTrap.muontrap_path()` returns an absolute path like `_build/dev/lib/muontrap/priv/muontrap`. Its CLI:

```
muontrap [options] -- cmd [cmd-args...]
```

Commonly used options:

| Flag | Purpose |
|---|---|
| `--delay-to-sigkill <ms>` | On parent death, send SIGTERM, wait `<ms>`, then SIGKILL. Default 0 (immediate SIGKILL). Reasonable: 2000–10000. |
| `--cgroup <path>` | Linux cgroup v1 path to add child to. Ignored on macOS. |
| `--controller <name>` | Cgroup controller (e.g. `memory`, `cpu`). Linux only. |
| `--group <name>` | Cgroup group name under controller. Linux only. |
| `--uid <user>` | Run child as this user (requires setuid permission). |
| `--gid <group>` | Run child as this group. |
| `--` | End of wrapper opts; everything after is the target command + args. |

Env vars: pass via Port's `{:env, list}` option; they are inherited by the wrapper which passes them to the child.

**About `--capture-output`:** this flag enables forwarding of child stdout to the parent Port. BUT it also repurposes the wrapper's own stdin as an ack-byte-counting channel (`MuonTrap.Port.encode_acks/1`) — meaning `Port.command/2` bytes from Elixir are decoded as ack counts and do NOT reach the child. This is the core constraint behind Mode 3's three-way trade-off. Use `--capture-output` only for Mode 3a (stdout-only + cleanup); never for Mode 3c (bidirectional).

---

## Cleanup guarantees per platform

| Platform | Mechanism | Handles BEAM SIGKILL? |
|---|---|---|
| Linux (any kernel ≥ 3.4) | `prctl(PR_SET_PDEATHSIG)` + cgroup (if configured) | ✅ Yes |
| macOS (any version) | `kqueue EVFILT_PROC + EV_NOTE_EXIT` on parent pid | ✅ Yes |
| FreeBSD | `procctl PROC_PDEATHSIG_CTL` | ✅ Yes (1.7+) |
| Windows | Not supported | ❌ |

**Integration test for cleanup:** kill the BEAM process with SIGKILL (not normal exit), then poll `pgrep -f <child_cmd>` for up to 10 seconds. Should return empty. If it doesn't, something's wrong.

---

## Common mistakes

### ❌ Inventing stdin APIs on Daemon

```elixir
# WRONG — these do not exist:
MuonTrap.Daemon.send(daemon, bytes)
MuonTrap.Daemon.write_stdin(daemon, bytes)
MuonTrap.Daemon.port(daemon)
MuonTrap.Daemon.send_input(daemon, bytes)
```

**Fix:** use Mode 3 (Port + muontrap binary wrapper). Daemon does not expose any stdin access.

### ❌ Locating the binary by hand

```elixir
# WRONG — this path may not exist and changes between Elixir/OTP releases:
Path.join(:code.priv_dir(:muontrap), "muontrap")
"deps/muontrap/priv/muontrap"  # also wrong — only works in dev
```

**Fix:** `MuonTrap.muontrap_path()`. It handles `_build`, release bundles, and platform variations.

### ❌ Assuming stdout arrives as complete lines without `{:line, N}`

```elixir
# Without :line option, you get {:data, bytes} with arbitrary chunking
Port.open(cmd, [:binary, :exit_status])  # → partial line bytes
```

**Fix:** Include `{:line, 4096}` (or larger). Messages become `{port, {:data, {eol_flag, line}}}` where `eol_flag ∈ [:eol, :noeol]`. Only `:eol` means a complete line.

### ❌ Forgetting `:exit_status` option

Without it, you don't get notified when the child exits — your GenServer waits forever. Always include.

### ❌ Not monitoring the Port

`Port.open/2` returns a port, not a pid. Ports send messages to the creating process. If the creator is not the GenServer's own process (e.g. you open the port in a helper), messages go elsewhere. Always open the port in `init/1` of the owning GenServer.

### ❌ Using `System.cmd` in production for long-running processes

`System.cmd` does NOT clean up orphans on BEAM SIGKILL. Even in tests, prefer `MuonTrap.cmd` — it's a drop-in replacement.

### ❌ Using `os.cmd` from Erlang

Same problem. Prefer MuonTrap.

---

## When to use each mode (decision table)

| Requirement | stdin? | stdout read? | BEAM-exit cleanup? | Mode |
|---|---|---|---|---|
| Short-lived, capture-all-output | — | ✓ | ✓ (via caller process exit) | `MuonTrap.cmd/3` |
| Long-running daemon, stdout to Logger | — | ✓ | ✓ | `MuonTrap.Daemon` (= Mode 3a) |
| Long-running, stdout-only + cleanup | ❌ | ✓ | ✓ | Mode 3a (use `MuonTrap.Daemon` with log_output/forwarding) |
| Fire-and-forget with startup kick | ✓ (startup) | ❌ | ✓ | Mode 3b (`MuonTrap.cmd` with stdin pipe) — rare |
| Bidirectional interactive (tmux, Python sidecar, REPL) | ✓ | ✓ | **app-layer** (not kernel) | Mode 3c (plain Port, no muontrap wrapper) |
| Pool of workers | — | — | — | Wrap any mode in a DynamicSupervisor |

**The key row** is the last one: if you need bidirectional interactive I/O, the muontrap wrapper is actively in your way (its stdin-as-ack-channel breaks `Port.command/2`). Accept app-layer cleanup as the trade-off, or switch to `erlexec`.

---

## Testing patterns

### Cleanup assertion

```elixir
test "child OS process dies within 10s of Elixir owner kill" do
  {:ok, pid} = MyWrapper.start_link(exe: "sleep", args: ["60"])
  {:ok, os_pid} = MyWrapper.os_pid(pid)

  Process.exit(pid, :kill)

  assert Enum.reduce_while(1..20, nil, fn _, _ ->
    case System.cmd("ps", ["-p", Integer.to_string(os_pid)]) do
      {_, 0} -> :timer.sleep(500); {:cont, nil}
      {_, _} -> {:halt, :gone}
    end
  end) == :gone
end
```

### Mode-3 stdin/stdout round-trip

```elixir
test "echo sidecar round-trip" do
  {:ok, pid} = MyInteractive.start_link(
    exe: "cat",              # echoes stdin to stdout
    args: [],
    subscriber: self()
  )

  MyInteractive.write(pid, "hello\n")

  assert_receive {:child_line, "hello"}, 2000
  GenServer.stop(pid)
end
```

---

## See also

- Official docs: https://hexdocs.pm/muontrap/1.7.0/
- Source + README: https://github.com/fhunleth/muontrap
- ESR usage: `runtime/lib/esr/os_process.ex` (Mode 3 底座), `runtime/lib/esr/tmux_process.ex`, `runtime/lib/esr/py_process.ex`.
- Alternative: `:erlexec` (GitHub issue #7 discussion). More features, more complexity. MuonTrap is sufficient for our needs.
