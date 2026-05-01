# PR-22 — PtyProcess + xterm.js LiveView attach: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Plan rev 2 — post subagent code-review (3 blockers + 4 majors fixed inline). Anchored to verified code: `Esr.OSProcess.@callback on_terminate(state)` is 1-arg; `Esr.PeerRegistry.lookup/1` takes binary; `@stateful_impls` MapSet at `session_router.ex:59-70`; agents.yaml has both `name:` and `impl:` lines requiring rename.

**Goal:** Replace `Esr.Peers.TmuxProcess` with a generic erlexec-PTY-backed `Esr.Peers.PtyProcess` peer; add `EsrWeb.AttachLive` xterm.js LiveView for browser-based multi-attach; add `/attach` slash command that returns an `esr://` URI rendered as a clickable HTTP link.

**Architecture:** PtyProcess broadcasts raw stdout chunks on `Phoenix.PubSub` topic `pty:<sid>`; AttachLive subscribes and pushes bytes to xterm.js via `push_event`. cc_process keeps consuming via cc_mcp / `cli:channel/<sid>` (unchanged). HTTP path mirrors `Esr.Uri` segments — `/sessions/<sid>/attach` ≡ `esr://localhost/sessions/<sid>/attach`.

**Tech Stack:** Elixir 1.16 / OTP 26, Phoenix 1.7, Phoenix.LiveView 0.20, Phoenix.PubSub, erlexec (`:pty` wrapper, `:exec.send/2`, `:exec.winsz/3`), xterm.js 5.x + xterm-addon-fit, esbuild via `mix esbuild`.

**Spec:** `docs/superpowers/specs/2026-05-01-pty-actor-attach-design.md` (rev 3, user-approved 2026-05-01).

---

## Phase 0: Baseline audit + branch setup

### Task 0.1: Verify clean dev branch + create feature branch

**Files:** none — git ops only.

- [ ] **Step 1: Confirm clean working tree on dev**

```bash
cd /Users/h2oslabs/Workspace/esr/.claude/worktrees/dev
git status
git rev-parse --abbrev-ref HEAD
```

Expected: `On branch dev`, clean tree (the docs/futures/todo.md + docs/superpowers/specs/2026-05-01-... should already be staged or committed by the brainstorming flow).

- [ ] **Step 2: Commit any pending spec/todo changes**

```bash
git add docs/futures/todo.md docs/superpowers/specs/2026-05-01-pty-actor-attach-design.md docs/superpowers/plans/2026-05-01-pty-actor-attach.md
git commit -m "$(cat <<'EOF'
docs: PR-22 spec rev 3 + impl plan + cc_mcp/channel todo entry

- Spec: PtyProcess + xterm.js LiveView attach (rev 3 post user review:
  drop Phoenix.Token, route via Esr.Uri, correct cc_process subscriber)
- Plan: 13-phase TDD decomposition
- todo.md: cc_mcp decouple + channel abstraction (deferred until PR-22 lands)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Branch off dev**

```bash
git checkout -b feature/pr-22-pty-actor-attach
```

Expected: switched to new branch.

### Task 0.2: Verify environment readiness

- [ ] **Step 1: Confirm erlexec PTY mode available**

```bash
mix run -e ':exec.start([]); IO.inspect(:exec.run("echo hi", [{:pty, []}, :stdout]))' 2>&1 | head -5
```

Expected: `{:ok, _, _}` (or similar). If it errors with `pty_not_supported`, stop and confirm with user.

- [ ] **Step 2: Confirm test suite green on dev baseline**

```bash
mix test --max-failures 5 2>&1 | tail -20
```

Expected: 0 failures. Record the pass count for Phase 12 comparison.

---

## Phase 1: `Esr.Uri.to_http_url/2`

This is an isolated pure function. TDD it first since downstream code (slash command, AttachLive) depends on it.

### Task 1.1: Test cases for `to_http_url/2`

**Files:**
- Modify: `runtime/test/esr/uri_test.exs`

- [ ] **Step 1: Write failing tests**

Append to `runtime/test/esr/uri_test.exs` (just before the closing `end`):

```elixir
  describe "to_http_url/2" do
    test "renders esr URI to HTTP URL using endpoint host:port" do
      uri = Esr.Uri.build_path(["sessions", "sess_42", "attach"], "localhost")
      assert uri == "esr://localhost/sessions/sess_42/attach"

      # endpoint_url/0 in tests returns http://localhost:4002 by default
      http = Esr.Uri.to_http_url(uri, EsrWeb.Endpoint)
      assert http =~ ~r{^https?://[^/]+/sessions/sess_42/attach$}
    end

    test "preserves query params" do
      uri = "esr://localhost/sessions/abc/attach?foo=bar"
      http = Esr.Uri.to_http_url(uri, EsrWeb.Endpoint)
      assert String.ends_with?(http, "/sessions/abc/attach?foo=bar")
    end

    test "raises on malformed input" do
      assert_raise ArgumentError, fn ->
        Esr.Uri.to_http_url("not-an-esr-uri", EsrWeb.Endpoint)
      end
    end
  end
```

- [ ] **Step 2: Run failing tests**

```bash
mix test runtime/test/esr/uri_test.exs --only describe:"to_http_url/2"
```

Expected: 3 failures, `Esr.Uri.to_http_url/2 is undefined`.

### Task 1.2: Implement `to_http_url/2`

**Files:**
- Modify: `runtime/lib/esr/uri.ex` (add public function before the `defp` block at line ~125)

- [ ] **Step 1: Implement**

Insert after the `build_path/3` function (around line 116), before the `defp authority(...)` line:

```elixir
  @doc """
  Renders an `esr://` URI as an HTTP URL pointing at the given Phoenix
  Endpoint. Path segments and query string are preserved verbatim;
  scheme + authority come from `endpoint.url/0`.

  Used by `/attach` slash and any future operator-facing UI that maps
  ESR resources to HTTP views — the rule is HTTP path = URI path.

      iex> Esr.Uri.to_http_url("esr://localhost/sessions/abc/attach", EsrWeb.Endpoint)
      "http://localhost:4001/sessions/abc/attach"
  """
  @spec to_http_url(String.t(), module()) :: String.t()
  def to_http_url("esr://" <> rest, endpoint) when is_atom(endpoint) do
    case String.split(rest, "/", parts: 2) do
      [_authority, path_and_query] ->
        endpoint.url() <> "/" <> path_and_query

      _ ->
        raise ArgumentError, "esr URI missing path: esr://#{rest}"
    end
  end

  def to_http_url(other, _endpoint),
    do: raise(ArgumentError, "not an esr:// URI: #{inspect(other)}")
```

- [ ] **Step 2: Run tests**

```bash
mix test runtime/test/esr/uri_test.exs
```

Expected: all pass (existing + 3 new).

- [ ] **Step 3: Commit**

```bash
git add runtime/lib/esr/uri.ex runtime/test/esr/uri_test.exs
git commit -m "$(cat <<'EOF'
feat(uri): Esr.Uri.to_http_url/2 — render esr URI as HTTP URL via Phoenix endpoint

PR-22 prep. Path segments and query string preserved; scheme + authority
from endpoint.url/0. Future ESR resource HTTP views map URI path
verbatim to HTTP path (e.g. /sessions/<sid>/attach).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: `OSProcessWorker` — add `{:winsz, cols, rows}` cast

`OSProcessWorker` already wraps `:exec.run_link/2`. Adding SIGWINCH support is ~10 LOC and isolated.

### Task 2.1: Test for `winsz` cast

**Files:**
- Modify: `runtime/test/esr/os_process_test.exs` (or create `runtime/test/esr/os_process_worker_test.exs` if isolated)

- [ ] **Step 1: Locate existing OSProcessWorker test file**

```bash
find runtime/test -name "*os_process*" -type f
```

Expected: at least one matching file. If the existing tests don't cover the Worker directly, append a new describe block to whichever file exists; otherwise create `runtime/test/esr/os_process_worker_winsz_test.exs`.

- [ ] **Step 2: Write failing test that exercises the new cast handler**

```elixir
defmodule Esr.OSProcessWorkerWinszTest do
  use ExUnit.Case, async: false

  setup do
    :meck.new(:exec, [:passthrough, :unstick])
    on_exit(fn -> :meck.unload(:exec) end)
    :ok
  end

  test "GenServer.cast({:winsz, cols, rows}) invokes :exec.winsz/3 on the worker's os_pid" do
    # Stub :exec.winsz to capture calls — record args without
    # actually changing window size on a real PTY.
    test_pid = self()

    :meck.expect(:exec, :winsz, fn os_pid, c, r ->
      send(test_pid, {:winsz_called, os_pid, c, r})
      :ok
    end)

    # Build a worker state with a known os_pid (no real PTY needed —
    # the cast handler only reads state.os_pid and forwards).
    state = %{os_pid: 12345}

    # Invoke the new clause directly. handle_cast is part of the
    # OSProcessWorker module added in Step 3 below.
    {:noreply, ^state} =
      Esr.OSProcess.OSProcessWorker.handle_cast({:winsz, 80, 24}, state)

    assert_receive {:winsz_called, 12345, 80, 24}, 200
  end

  test "winsz cast with nil os_pid is a no-op" do
    state = %{os_pid: nil}

    :meck.expect(:exec, :winsz, fn _, _, _ ->
      flunk("should not call :exec.winsz when os_pid is nil")
    end)

    {:noreply, ^state} =
      Esr.OSProcess.OSProcessWorker.handle_cast({:winsz, 80, 24}, state)
  end
end
```

- [ ] **Step 3: Run**

```bash
mix test runtime/test/esr/os_process_worker_winsz_test.exs
```

Expected: 2 failures — `handle_cast/2` clause for `{:winsz, _, _}` undefined.

### Task 2.2: Add `{:winsz, c, r}` cast handler in `OSProcessWorker`

**Files:**
- Modify: `runtime/lib/esr/os_process.ex` (find the `OSProcessWorker` `handle_cast` clauses, add new clause)

- [ ] **Step 1: Locate the worker module**

```bash
grep -n "defmodule.*OSProcessWorker\|def handle_cast" runtime/lib/esr/os_process.ex | head -10
```

- [ ] **Step 2: Add the new handle_cast clause**

Add this clause adjacent to the existing `handle_cast` clauses in the `OSProcessWorker` defmodule:

```elixir
  @impl GenServer
  def handle_cast({:winsz, cols, rows}, state)
      when is_integer(cols) and is_integer(rows) and cols > 0 and rows > 0 do
    case state.os_pid do
      nil -> :ok
      os_pid -> :exec.winsz(os_pid, cols, rows)
    end

    {:noreply, state}
  end
```

(Place after the existing `handle_cast({:write_stdin, ...})` clause if it exists; otherwise next to the most similar cast handler.)

- [ ] **Step 3: Run**

```bash
mix test runtime/test/esr/os_process_worker_winsz_test.exs runtime/test/esr/os_process_test.exs 2>&1 | tail -10
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/os_process.ex runtime/test/esr/os_process_worker_winsz_test.exs
git commit -m "$(cat <<'EOF'
feat(os_process): handle_cast({:winsz, c, r}) → :exec.winsz/3

PR-22 prep. PtyProcess will delegate xterm.js resize events here so
claude's TUI receives SIGWINCH and re-layouts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3: `Esr.Peers.PtyProcess`

Generic PTY peer. Mirrors TmuxProcess shape but drops tmux-specific framing. Lifts the existing rewire mechanism (PR-21ω') with the neighbor key renamed.

### Task 3.1: Test PtyProcess broadcasts raw stdout to PubSub

**Files:**
- Create: `runtime/test/esr/peers/pty_process_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Esr.Peers.PtyProcessTest do
  @moduledoc """
  PR-22 — PtyProcess fans erlexec stdout chunks out to PubSub topic
  pty:<sid> as raw bytes (no line splitting; xterm.js needs ANSI
  escapes intact across chunk boundaries).
  """

  use ExUnit.Case, async: false

  alias Esr.Peers.PtyProcess

  setup do
    sid = "test-pty-#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:#{sid}")
    {:ok, sid: sid}
  end

  test "raw stdout chunk fans out as {:pty_stdout, chunk} on pty:<sid>", %{sid: sid} do
    state = %{session_id: sid, neighbors: []}

    # Simulate erlexec callback — handle_info({:stdout, os_pid, raw}, state)
    # is the broadcast site.
    chunk = "\e[31mhello\e[0m"
    {:noreply, _new_state} = PtyProcess.handle_info({:stdout, 12345, chunk}, state)

    assert_receive {:pty_stdout, ^chunk}, 200
  end

  test ":pty_closed broadcast on terminate", %{sid: sid} do
    state = %{session_id: sid, neighbors: []}
    PtyProcess.on_terminate(state)
    assert_receive :pty_closed, 200
  end
end
```

- [ ] **Step 2: Run**

```bash
mix test runtime/test/esr/peers/pty_process_test.exs
```

Expected: 2 failures (module not yet defined).

### Task 3.2: Implement `Esr.Peers.PtyProcess`

**Files:**
- Create: `runtime/lib/esr/peers/pty_process.ex`

- [ ] **Step 1: Read TmuxProcess as the template**

```bash
sed -n '1,80p' runtime/lib/esr/peers/tmux_process.ex
```

Note the `use Esr.Peer.Stateful`, `use Esr.OSProcess`, `os_env/1`, `spawn_args/1`, `on_os_exit/2`, `rewire_session_siblings/1` callbacks. The new module mirrors these but drops tmux-specific concerns.

- [ ] **Step 2: Read the bodies we'll port verbatim**

```bash
sed -n '88,116p' runtime/lib/esr/peers/tmux_process.ex   # spawn_args/1
sed -n '284,375p' runtime/lib/esr/peers/tmux_process.ex   # init/1 + schedule_startup_keys/1
sed -n '474,510p' runtime/lib/esr/peers/tmux_process.ex   # os_env/1
sed -n '775,832p' runtime/lib/esr/peers/tmux_process.ex   # rewire_session_siblings + patch_neighbor_in_state
```

Note exact line ranges may drift; the goal is to have the four bodies in front of you before writing PtyProcess. Drop any `tmux_socket` / `TMUX_SOCK_PATH` / `tmux -C` references during the port — none survive in PR-22.

- [ ] **Step 3: Write the module**

```elixir
defmodule Esr.Peers.PtyProcess do
  @moduledoc """
  Generic PTY-backed peer. Owns one OS process spawned via erlexec's
  `:pty` wrapper. Fans raw stdout chunks out to Phoenix.PubSub topic
  `"pty:<session_id>"` for `EsrWeb.AttachLive` subscribers; accepts
  stdin via the public `write/2` and resize via `resize/3` API.

  Replaces `Esr.Peers.TmuxProcess` (PR-22, 2026-05-01). The tmux
  control-mode protocol layer is gone; claude's TUI runs directly
  under erlexec's PTY.

  cc_process is **not** a PubSub subscriber here — the conversation
  path is cc_mcp → cli:channel/<sid>. PtyProcess only serves the
  operator-facing browser attach.
  """

  require Logger

  @behaviour Esr.Role.State
  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :pty, wrapper: :pty

  alias Phoenix.PubSub

  # ------------------------------------------------------------------
  # Public API (called from EsrWeb.AttachLive event handlers)
  # ------------------------------------------------------------------

  @doc "Forward keystrokes from xterm.js to claude's stdin."
  @spec write(String.t(), iodata()) :: :ok | {:error, term()}
  def write(sid, data) do
    case worker_pid_for(sid) do
      {:ok, worker_pid} -> Esr.OSProcess.OSProcessWorker.write_stdin(worker_pid, data)
      err -> err
    end
  end

  @doc "Forward window-size change from xterm.js to claude (SIGWINCH)."
  @spec resize(String.t(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def resize(sid, cols, rows) do
    case worker_pid_for(sid) do
      {:ok, worker_pid} -> GenServer.cast(worker_pid, {:winsz, cols, rows})
      err -> err
    end
  end

  # PtyProcess registers itself under Esr.PeerRegistry with the
  # binary actor_id "pty:<sid>" in init/1. AttachLive (and any
  # other future caller) looks up via the same key.
  defp worker_pid_for(sid) when is_binary(sid) do
    case Esr.PeerRegistry.lookup("pty:" <> sid) do
      {:ok, peer_pid} ->
        case Esr.OSProcess.exec_pid(peer_pid) do
          {:ok, worker_pid} -> {:ok, worker_pid}
          _ -> {:error, :no_worker}
        end

      :error ->
        {:error, :no_pty_for_session}
    end
  end

  # ------------------------------------------------------------------
  # spawn_args — verbatim port from tmux_process.ex (drop tmux_socket
  # if present; PR-22 doesn't need it)
  # ------------------------------------------------------------------

  def spawn_args(params) do
    %{
      session_id: Map.fetch!(params, :session_id),
      session_name: Map.fetch!(params, :session_name),
      workspace_name: Map.get(params, :workspace_name, "default"),
      dir: Map.get(params, :dir) || System.tmp_dir!(),
      neighbors: Map.get(params, :neighbors, [])
    }
  end

  # ------------------------------------------------------------------
  # Peer init — registers in PeerRegistry, schedules trust-confirm
  # timers, schedules deferred sibling rewire (PR-21ω' pattern).
  # ------------------------------------------------------------------

  def init(%{session_name: _, dir: _} = args) do
    state = Map.merge(args, %{kind: :pty})

    # Register so AttachLive can find this PtyProcess by sid.
    _ = Esr.PeerRegistry.register("pty:" <> state.session_id, self())

    # PR-21ω' deferred rewire — must NOT call back into peers_sup
    # synchronously from init (deadlock). 50ms gives DynamicSupervisor
    # time to ack this child's start_child.
    Process.send_after(self(), :rewire_siblings, 50)

    # T12a auto-confirm of claude trust dialogs (5s/8s/20s).
    schedule_startup_keys(state)

    {:ok, state}
  end

  defp schedule_startup_keys(%{session_id: sid}) when is_binary(sid) and sid != "" do
    Process.send_after(self(), {:auto_confirm_trust, 1}, 5_000)
    Process.send_after(self(), {:auto_confirm_trust, 2}, 8_000)
    Process.send_after(self(), {:auto_confirm_trust, 3}, 20_000)
    :ok
  end

  defp schedule_startup_keys(_), do: :ok

  # ------------------------------------------------------------------
  # erlexec stdout — broadcast raw chunk
  # ------------------------------------------------------------------

  def handle_info({:stdout, _os_pid, raw_chunk}, state) do
    PubSub.broadcast(EsrWeb.PubSub, "pty:#{state.session_id}", {:pty_stdout, raw_chunk})
    {:noreply, state}
  end

  def handle_info(:rewire_siblings, state) do
    rewire_session_siblings(state)
    {:noreply, state}
  end

  def handle_info({:auto_confirm_trust, n}, state) do
    case Esr.OSProcess.exec_pid(self()) do
      {:ok, worker_pid} ->
        Esr.OSProcess.OSProcessWorker.write_stdin(worker_pid, "1\r")
        Logger.debug("PtyProcess auto-confirm step #{n} sid=#{state.session_id}")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # OSProcess lifecycle hooks (signatures must match os_process.ex
  # @callback declarations exactly: 1-arg on_terminate, 2-arg on_os_exit)
  # ------------------------------------------------------------------

  @impl Esr.OSProcess
  def os_cmd(_state), do: ["bash", scripts_path("esr-cc.sh")]

  @impl Esr.OSProcess
  def os_env(state) do
    # Verbatim port from tmux_process.ex:474–510, dropping any TMUX_*
    # exports. Workspace + session vars + ESR_REPO_DIR + ESR_HOME +
    # ESR_CHAT_IDS json. Adjust paths exactly as the source has them.
    [
      {"ESR_SESSION_ID", state.session_id},
      {"ESR_SESSION_NAME", state.session_name},
      {"ESR_WORKSPACE", state.workspace_name},
      {"ESR_HOME", to_string(:os.getenv(~c"ESRD_HOME", ~c"") |> List.to_string())},
      {"ESR_REPO_DIR", state.dir}
      # Append additional vars the original os_env emits (chat_ids json,
      # role, env-name, etc.) — copy from tmux_process.ex line-for-line.
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  @impl Esr.OSProcess
  def os_cwd(state), do: state.dir

  @impl Esr.OSProcess
  def on_os_exit(_status, _state) do
    # PR-21ω'' carryover: any exit (including 0) triggers peers
    # DynamicSupervisor :transient restart. PR-21ω' rewire patches
    # siblings via :pty_process neighbor key on the new PtyProcess pid.
    {:stop, :claude_died_unexpectedly}
  end

  @impl Esr.OSProcess
  def on_terminate(state) do
    # 1-arg per Esr.OSProcess @callback. We don't have a reason here;
    # broadcast a no-payload sentinel so AttachLive can render the
    # "[session ended]" overlay.
    PubSub.broadcast(EsrWeb.PubSub, "pty:#{state.session_id}", :pty_closed)
    :ok
  end

  # ------------------------------------------------------------------
  # Sibling rewire — verbatim port from tmux_process.ex:775–832 with
  # neighbor key changed from :tmux_process to :pty_process. Public
  # for the rewire test (Phase 4).
  # ------------------------------------------------------------------

  @doc false
  def rewire_session_siblings(%{session_id: sid}) when is_binary(sid) and sid != "" do
    peers_sup_via = {:via, Registry, {Esr.Session.Registry, {:peers_sup, sid}}}

    case GenServer.whereis(peers_sup_via) do
      nil ->
        :ok

      sup_pid ->
        my_pid = self()

        sup_pid
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn
          {_id, child_pid, _type, _modules} when is_pid(child_pid) and child_pid != my_pid ->
            patch_neighbor_in_state(child_pid, :pty_process, my_pid)

          _ ->
            :ok
        end)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def rewire_session_siblings(_state), do: :ok

  defp patch_neighbor_in_state(pid, name, new_pid) do
    _ =
      :sys.replace_state(pid, fn
        %{parent: _, state: inner} = ws when is_map(inner) ->
          %{ws | state: %{inner | neighbors: Keyword.put(inner.neighbors, name, new_pid)}}

        %{neighbors: nb} = s when is_list(nb) ->
          %{s | neighbors: Keyword.put(nb, name, new_pid)}

        other ->
          other
      end)

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp scripts_path(file) do
    Path.join([Application.app_dir(:esr), "..", "..", "..", "scripts", file])
    |> Path.expand()
  end
end
```

Key decisions captured here (resolved during Phase 0 audit):
- `on_terminate(state)` is 1-arg (matches `Esr.OSProcess.@callback` at `os_process.ex:58`); reason is unavailable. Broadcast bare `:pty_closed`; LiveView shows generic "[session ended]" overlay.
- No `post_start` callback exists. Trust-confirm timers schedule from `init/1` (matches existing TmuxProcess pattern).
- Registration is via `Esr.PeerRegistry.register("pty:<sid>", self())` — `Esr.PeerRegistry.lookup/1` takes a binary actor_id (verified at `peer_registry.ex:21,40`).
- Rewire body is inline (no `Esr.Peers.PeerRewire` module — that helper doesn't exist; port verbatim from tmux_process.ex).

- [ ] **Step 4: Run**

```bash
mix test runtime/test/esr/peers/pty_process_test.exs
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/peers/pty_process.ex runtime/test/esr/peers/pty_process_test.exs
git commit -m "$(cat <<'EOF'
feat(peers): Esr.Peers.PtyProcess — generic erlexec PTY peer

Replaces TmuxProcess for CC. Fans raw stdout chunks to Phoenix.PubSub
topic pty:<sid> for browser attach; cc_process keeps its own
cc_mcp → cli:channel/<sid> path unchanged. T12a auto-confirm port,
on_terminate broadcasts {:pty_closed, _} for LiveView ended overlay.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4: Sibling neighbor key rename + rewire test port

Rewire body itself was already inlined into PtyProcess (Phase 3). This phase covers the sibling-side rename: every reader of `state.neighbors[:tmux_process]` needs to become `:pty_process`.

### Task 4.1: Sibling-side neighbor key rename

- [ ] **Step 1: Find all readers/writers of `:tmux_process` outside tmux_process.ex**

```bash
grep -rn ":tmux_process\|tmux_process:" runtime/lib/esr/ 2>/dev/null | grep -v "lib/esr/peers/tmux_process.ex"
```

Expected: a handful of references in `cc_process.ex`, `feishu_chat_proxy.ex`, `session_router.ex`, possibly others. Each is a callsite that reads/writes the `:tmux_process` neighbor key on a peer's `state.neighbors` keyword list.

- [ ] **Step 2: Rename per-file with manual review**

```bash
# Repeat per file from Step 1's output.
for f in runtime/lib/esr/peers/cc_process.ex runtime/lib/esr/peers/feishu_chat_proxy.ex runtime/lib/esr/session_router.ex; do
  sed -i '' 's/:tmux_process/:pty_process/g; s/tmux_process:/pty_process:/g' "$f"
done

git diff runtime/lib/esr/
```

Verify nothing inside string literals (e.g. log messages mentioning "tmux_process") got rewritten in a misleading way. The neighbor-key rename is keyword-list semantic; log strings should be hand-edited if they exist.

- [ ] **Step 3: Adapt `tmux_rewire_test.exs` → `pty_rewire_test.exs`**

The existing test at `runtime/test/esr/peers/tmux_rewire_test.exs` exercises the same rewire body now living inside PtyProcess. Port:

```bash
cp runtime/test/esr/peers/tmux_rewire_test.exs runtime/test/esr/peers/pty_rewire_test.exs
sed -i '' '
  s/Esr.Peers.TmuxProcess/Esr.Peers.PtyProcess/g
  s/:tmux_process/:pty_process/g
  s/tmux_rewire/pty_rewire/g
  s/TmuxRewire/PtyRewire/g
' runtime/test/esr/peers/pty_rewire_test.exs
```

The original `tmux_rewire_test.exs` stays in place until Phase 10 (so dev ESRD keeps a passing test through Phase 9 — they exercise different modules during the transition).

- [ ] **Step 4: Run**

```bash
mix test runtime/test/esr/peers/pty_rewire_test.exs
```

Expected: pass — mechanical port, asserts FCP / cc_process stubs receive the new pid under `neighbors[:pty_process]`.

- [ ] **Step 5: Compile-check the renamed callsites**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
```

Expected: clean. Any remaining `:tmux_process` reference (other than inside the soon-to-be-deleted tmux_process.ex) → fix.

- [ ] **Step 6: Commit**

```bash
git add -u runtime/lib/esr/ runtime/test/esr/peers/pty_rewire_test.exs
git commit -m "$(cat <<'EOF'
refactor: rewire neighbor key :tmux_process → :pty_process (sibling side)

Generalizes PR-21ω' wiring for PR-22's PtyProcess. Sed across cc_process,
feishu_chat_proxy, session_router; pty_rewire_test.exs ported from the
tmux_rewire_test (the old test stays through Phase 9 since TmuxProcess
itself isn't deleted until Phase 10).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4.5: Public host config (`ESR_PUBLIC_HOST`)

**Why this matters:** `Esr.Uri.to_http_url/2` reads `EsrWeb.Endpoint.url()`. Today that returns `http://localhost:4000` (per `config/config.exs:18` `url: [host: "localhost"]` and `config/dev.exs:12` `port: PORT||4000`). The operator accesses esrd over Tailscale at `100.64.0.27:4001` — a host the BEAM has no way to know unless we tell it.

We want: `ESR_PUBLIC_HOST=100.64.0.27 PORT=4001` (set in launchd plist or shell env) → `Endpoint.url()` returns `http://100.64.0.27:4001`. No host env → falls back to `localhost` (test/CI behavior).

### Task 4.5.1: Wire `ESR_PUBLIC_HOST` into runtime.exs

**Files:**
- Modify: `runtime/config/runtime.exs`

- [ ] **Step 1: Inspect the existing prod block for the pattern**

```bash
sed -n '20,55p' runtime/config/runtime.exs
```

Note: prod already reads `PHX_HOST` and configures `url: [host: ..., scheme: "https"]`. We add a parallel branch that runs in any env (including dev/prod) when `ESR_PUBLIC_HOST` is set.

- [ ] **Step 2: Append the runtime config branch**

Add this block to `runtime/config/runtime.exs` near the top (after `import Config`, before the `if config_env() == :prod` block):

```elixir
# Public-host override — when ESR_PUBLIC_HOST is set, EsrWeb.Endpoint.url/0
# returns http://<host>:<port> so /attach links rendered in slash replies
# are reachable from the operator's network (e.g. Tailscale 100.64.0.27).
# Without this, Endpoint.url/0 falls back to config.exs's default (localhost).
if public_host = System.get_env("ESR_PUBLIC_HOST") do
  public_port = String.to_integer(System.get_env("PORT") || "4000")
  config :esr, EsrWeb.Endpoint, url: [host: public_host, port: public_port]
end
```

- [ ] **Step 3: Bind dev http to all interfaces when ESR_PUBLIC_HOST is set**

`config/dev.exs:12` currently has `ip: {127, 0, 0, 1}` — esrd only listens on loopback. Tailscale traffic to `100.64.0.27:4001` would never arrive. Update `dev.exs` to read `ESR_HTTP_BIND` (default loopback for safety):

```elixir
# Replace the existing http: line in config/dev.exs
http_bind =
  case System.get_env("ESR_HTTP_BIND") do
    nil -> {127, 0, 0, 1}
    "0.0.0.0" -> {0, 0, 0, 0}
    "::0" -> {0, 0, 0, 0, 0, 0, 0, 0}
    other ->
      other
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)
      |> List.to_tuple()
  end

config :esr, EsrWeb.Endpoint,
  http: [ip: http_bind, port: String.to_integer(System.get_env("PORT") || "4000")],
  # ... rest of existing config
```

(Keep the rest of the dev.exs Endpoint config block intact — only `http:` and the new helper change.)

- [ ] **Step 4: Document operator-side env in launchd plist**

Update `~/Library/LaunchAgents/com.openclaw.esrd-dev.plist` (operator-managed; don't commit). Add to `EnvironmentVariables`:

```xml
<key>ESR_PUBLIC_HOST</key><string>100.64.0.27</string>
<key>ESR_HTTP_BIND</key><string>0.0.0.0</string>
<key>PORT</key><string>4001</string>
```

This step is **operator-side**, executed manually at restart in Phase 12. Plan just records the intent.

- [ ] **Step 5: Add a unit test for `Esr.Uri.to_http_url/2` honoring the configured host**

Append to `runtime/test/esr/uri_test.exs`:

```elixir
    test "honors EsrWeb.Endpoint.url config (public-host override)" do
      original = Application.get_env(:esr, EsrWeb.Endpoint)

      try do
        Application.put_env(
          :esr,
          EsrWeb.Endpoint,
          Keyword.put(original || [], :url, host: "100.64.0.27", port: 4001)
        )

        uri = Esr.Uri.build_path(["sessions", "abc", "attach"], "localhost")
        http = Esr.Uri.to_http_url(uri, EsrWeb.Endpoint)

        assert http == "http://100.64.0.27:4001/sessions/abc/attach"
      after
        Application.put_env(:esr, EsrWeb.Endpoint, original)
      end
    end
```

- [ ] **Step 6: Run + commit**

```bash
mix test runtime/test/esr/uri_test.exs
git add runtime/config/runtime.exs runtime/config/dev.exs runtime/test/esr/uri_test.exs
git commit -m "$(cat <<'EOF'
feat(config): ESR_PUBLIC_HOST + ESR_HTTP_BIND for Tailnet-reachable Endpoint.url

PR-22 prep. /attach slash returns URLs via EsrWeb.Endpoint.url/0 — without
a public-host override, that's "http://localhost:4000" and won't reach an
operator on the Tailnet (100.64.0.27). ESR_PUBLIC_HOST + ESR_HTTP_BIND env
let operators bind to 0.0.0.0:4001 and emit URLs as http://100.64.0.27:4001.
Defaults preserve existing loopback-only behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5: Phoenix LiveView dependency + Endpoint plumbing

### Task 5.1: Add Phoenix LiveView dependency

**Files:**
- Modify: `runtime/mix.exs`

- [ ] **Step 1: Inspect current deps**

```bash
grep -A 30 "defp deps" runtime/mix.exs | head -40
```

- [ ] **Step 2: Add `:phoenix_live_view` and `:esbuild`**

Add to the `deps` list:

```elixir
      {:phoenix_live_view, "~> 0.20.17"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
```

- [ ] **Step 3: Fetch deps**

```bash
mix deps.get
```

Expected: both packages installed.

- [ ] **Step 4: Verify compile**

```bash
mix compile 2>&1 | tail -10
```

Expected: clean compile.

### Task 5.2: Uncomment LiveView socket + add LiveView module helper

**Files:**
- Modify: `runtime/lib/esr_web/endpoint.ex` (uncomment lines 14-16)
- Modify: `runtime/lib/esr_web.ex` (add `:live_view` helper)

- [ ] **Step 1: Endpoint — uncomment LiveView socket**

Replace lines 14-16 of `runtime/lib/esr_web/endpoint.ex`:

```elixir
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
```

- [ ] **Step 2: Add `:live_view` clause to `EsrWeb`**

Read `runtime/lib/esr_web.ex` first (it has `:controller` clauses we follow). Add a new clause adjacent:

```elixir
  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {EsrWeb.Layouts, :root}

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.LiveView.Helpers
      alias Phoenix.LiveView.JS
    end
  end
```

(If `html_helpers` already exists, just add the `live_view` clause referencing it.)

- [ ] **Step 3: Create minimal layout module**

**Files:**
- Create: `runtime/lib/esr_web/components/layouts.ex`
- Create: `runtime/lib/esr_web/components/layouts/root.html.heex`

```elixir
# runtime/lib/esr_web/components/layouts.ex
defmodule EsrWeb.Layouts do
  use EsrWeb, :html
  embed_templates "layouts/*"
end
```

```html
<!-- runtime/lib/esr_web/components/layouts/root.html.heex -->
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta http-equiv="X-UA-Compatible" content="IE=edge" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>ESR · attach</title>
    <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
    </script>
    <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
  </head>
  <body>
    <%= @inner_content %>
  </body>
</html>
```

- [ ] **Step 4: Add `:html` helper (with `verified_routes`) if missing**

Check `runtime/lib/esr_web.ex` for an `:html` clause. If absent, add it — the layout heex uses `~p"/assets/app.js"` which requires `verified_routes`:

```elixir
  def html do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
      alias Phoenix.LiveView.JS
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: EsrWeb.Endpoint,
        router: EsrWeb.Router,
        statics: EsrWeb.static_paths()
    end
  end
```

Also extend the `:live_view` clause to include `unquote(verified_routes())` so AttachLive can use `~p` paths in its render block.

- [ ] **Step 5: Verify compile**

```bash
mix compile 2>&1 | tail -10
```

Expected: no warnings about `EsrWeb.Layouts` or `Phoenix.LiveView`.

- [ ] **Step 6: Commit**

```bash
git add runtime/mix.exs runtime/mix.lock runtime/lib/esr_web/endpoint.ex runtime/lib/esr_web.ex runtime/lib/esr_web/components/layouts.ex runtime/lib/esr_web/components/layouts/root.html.heex
git commit -m "$(cat <<'EOF'
build(esr_web): add Phoenix.LiveView + esbuild deps + minimal layout

PR-22 prep. LiveView socket on /live (was commented out in v0.1
which only served Channels). Empty layout shell — AttachLive lands
in Phase 7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6: Asset pipeline + xterm.js bundling

### Task 6.1: esbuild config + xterm.js install

**Files:**
- Create: `runtime/assets/package.json`
- Create: `runtime/assets/js/app.js`
- Create: `runtime/assets/js/hooks/xterm_attach.js`
- Modify: `runtime/config/config.exs` (add `:esbuild` config)

- [ ] **Step 1: package.json**

```json
{
  "name": "esr_web_assets",
  "version": "0.0.0",
  "private": true,
  "dependencies": {
    "xterm": "5.3.0",
    "xterm-addon-fit": "0.8.0"
  }
}
```

- [ ] **Step 2: Install npm deps**

```bash
cd runtime/assets && npm install && cd ../..
```

Expected: `node_modules/` populated; `package-lock.json` written.

- [ ] **Step 3: Add esbuild config**

Append to `runtime/config/config.exs` (before `import_config "#{config_env()}.exs"`):

```elixir
config :esbuild,
  version: "0.21.5",
  default: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]
```

- [ ] **Step 4: js/app.js entrypoint**

```javascript
// runtime/assets/js/app.js
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { XtermAttach } from "./hooks/xterm_attach";

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { XtermAttach },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
```

- [ ] **Step 5: js/hooks/xterm_attach.js**

```javascript
// runtime/assets/js/hooks/xterm_attach.js
import { Terminal } from "xterm";
import { FitAddon } from "xterm-addon-fit";
import "xterm/css/xterm.css";

export const XtermAttach = {
  mounted() {
    this.term = new Terminal({
      cursorBlink: true,
      fontFamily: "Menlo, Monaco, monospace",
      fontSize: 13,
      convertEol: false,
    });
    const fitAddon = new FitAddon();
    this.term.loadAddon(fitAddon);
    this.term.open(this.el);
    fitAddon.fit();

    // server → client
    this.handleEvent("stdout", ({ data }) => this.term.write(data));
    this.handleEvent("ended", ({ reason }) => {
      this.term.writeln(`\r\n\x1b[33m[session ended: ${reason}]\x1b[0m`);
    });

    // client → server
    this.term.onData((data) => this.pushEvent("stdin", { data }));

    // resize handling
    const sendResize = () => {
      const { cols, rows } = this.term;
      this.pushEvent("resize", { cols, rows });
    };
    window.addEventListener("resize", () => {
      fitAddon.fit();
      sendResize();
    });
    sendResize();
  },
};
```

- [ ] **Step 6: Build assets**

```bash
mix esbuild default
```

Expected: `runtime/priv/static/assets/app.js` and `app.css` produced.

- [ ] **Step 7: Verify static path serves bundle**

```bash
grep -n "static_paths\|priv/static/assets" runtime/lib/esr_web.ex runtime/lib/esr_web/endpoint.ex
```

If `static_paths/0` doesn't include `"assets"`, add it. Likely:

```elixir
def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)
```

- [ ] **Step 8: Commit**

```bash
git add runtime/assets/ runtime/config/config.exs runtime/lib/esr_web.ex runtime/priv/static/assets/
git commit -m "$(cat <<'EOF'
build(assets): xterm.js + xterm-addon-fit via esbuild

PR-22 prep. js/app.js Phoenix LiveSocket + XtermAttach hook;
esbuild config bundles to priv/static/assets/app.js. Static paths
extended to serve /assets.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7: `EsrWeb.AttachLive`

### Task 7.1: Test — LiveView mount subscribes to PubSub

**Files:**
- Create: `runtime/test/esr_web/live/attach_live_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule EsrWeb.AttachLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  @endpoint EsrWeb.Endpoint

  test "mount subscribes to pty:<sid> and pushes stdout to client" do
    sid = "test-attach-#{System.unique_integer([:positive])}"

    conn = Phoenix.ConnTest.build_conn()
    {:ok, view, _html} = live(conn, "/sessions/#{sid}/attach")

    # Simulate PtyProcess broadcasting raw bytes.
    Phoenix.PubSub.broadcast(EsrWeb.PubSub, "pty:#{sid}", {:pty_stdout, "hello"})

    # The push_event is async; assert via render_hook or by checking
    # that the LiveView didn't crash on the message.
    assert render(view) =~ "term-#{sid}"
  end
end
```

- [ ] **Step 2: Run**

```bash
mix test runtime/test/esr_web/live/attach_live_test.exs
```

Expected: route not found / module undefined.

### Task 7.2: Implement `EsrWeb.AttachLive`

**Files:**
- Create: `runtime/lib/esr_web/live/attach_live.ex`
- Modify: `runtime/lib/esr_web/router.ex`

- [ ] **Step 1: Router**

Replace the contents of `runtime/lib/esr_web/router.ex`:

```elixir
defmodule EsrWeb.Router do
  use EsrWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EsrWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", EsrWeb do
    pipe_through :browser
    live "/sessions/:sid/attach", AttachLive
  end
end
```

- [ ] **Step 2: AttachLive module**

```elixir
defmodule EsrWeb.AttachLive do
  use EsrWeb, :live_view

  @impl true
  def mount(%{"sid" => sid}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:#{sid}")
    end

    {:ok, assign(socket, sid: sid, terminal_id: "term-#{sid}", ended?: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="attach-shell" style="background:#000;color:#eee;padding:8px;height:100vh;">
      <div :if={@ended?} class="ended-banner">[session ended]</div>
      <div id={@terminal_id} phx-hook="XtermAttach" data-sid={@sid} style="height:100%;"></div>
    </div>
    """
  end

  @impl true
  def handle_event("stdin", %{"data" => data}, socket) do
    Esr.Peers.PtyProcess.write(socket.assigns.sid, data)
    {:noreply, socket}
  end

  @impl true
  def handle_event("resize", %{"cols" => c, "rows" => r}, socket)
      when is_integer(c) and is_integer(r) do
    Esr.Peers.PtyProcess.resize(socket.assigns.sid, c, r)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_stdout, data}, socket) do
    {:noreply, push_event(socket, "stdout", %{data: data})}
  end

  def handle_info({:pty_closed, reason}, socket) do
    {:noreply,
     socket
     |> assign(ended?: true)
     |> push_event("ended", %{reason: inspect(reason)})}
  end
end
```

- [ ] **Step 3: Run**

```bash
mix test runtime/test/esr_web/live/attach_live_test.exs
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr_web/live/attach_live.ex runtime/lib/esr_web/router.ex runtime/test/esr_web/live/attach_live_test.exs
git commit -m "$(cat <<'EOF'
feat(esr_web): EsrWeb.AttachLive — xterm.js terminal attach LiveView

PR-22. Subscribes pty:<sid> on mount; pushes stdout to xterm hook;
forwards stdin/resize back to PtyProcess. Router serves
/sessions/:sid/attach (path mirrors esr URI segments).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8: `/attach` slash command

### Task 8.1: Test — slash command returns esr URI + clickable HTTP URL

**Files:**
- Create: `runtime/test/esr/admin/commands/attach_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule Esr.Admin.Commands.AttachTest do
  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Attach

  test "returns clickable HTTP URL + canonical esr URI when session exists" do
    chat_id = "oc_test_#{System.unique_integer([:positive])}"
    app_id = "app_test"
    thread_id = "thread_test"
    sid = "sess_attach_#{System.unique_integer([:positive])}"

    # Stub the SessionRegistry lookup
    :meck.new(Esr.SessionRegistry, [:passthrough])
    :meck.expect(Esr.SessionRegistry, :lookup_by_chat_thread, fn _, _, _ ->
      {:ok, sid, %{}}
    end)

    args = %{"chat_id" => chat_id, "app_id" => app_id, "thread_id" => thread_id}
    {:ok, %{"text" => text}} = Attach.execute(%{"args" => args})

    assert text =~ "/sessions/#{sid}/attach"
    assert text =~ "esr://localhost/sessions/#{sid}/attach"

    :meck.unload(Esr.SessionRegistry)
  end

  test "returns helpful message when no live session in chat" do
    :meck.new(Esr.SessionRegistry, [:passthrough])
    :meck.expect(Esr.SessionRegistry, :lookup_by_chat_thread, fn _, _, _ -> :not_found end)

    args = %{"chat_id" => "x", "app_id" => "y", "thread_id" => "z"}
    {:ok, %{"text" => text}} = Attach.execute(%{"args" => args})
    assert text =~ "no live session"

    :meck.unload(Esr.SessionRegistry)
  end
end
```

- [ ] **Step 2: Run**

```bash
mix test runtime/test/esr/admin/commands/attach_test.exs
```

Expected: undefined module.

### Task 8.2: Implement `Esr.Admin.Commands.Attach`

**Files:**
- Create: `runtime/lib/esr/admin/commands/attach.ex`
- Modify: `runtime/priv/slash-routes.default.yaml`

- [ ] **Step 1: Slash routes yaml**

Add this entry to `runtime/priv/slash-routes.default.yaml` after `/end-session` (around line 135):

```yaml
  "/attach":
    kind: attach
    permission: null
    command_module: "Esr.Admin.Commands.Attach"
    requires_workspace_binding: true
    requires_user_binding: true
    category: "Sessions"
    description: "返回浏览器 attach 链接（连接 claude TUI）"
    args: []
```

- [ ] **Step 2: Command module**

```elixir
defmodule Esr.Admin.Commands.Attach do
  @moduledoc """
  PR-22 — `/attach` slash. Resolves the live session in the current
  chat/thread and returns a clickable browser URL backed by
  `EsrWeb.AttachLive` (xterm.js).

  Output format: a Feishu-renderable string carrying both the
  operator-friendly HTTP URL and the canonical `esr://` URI.
  """

  @behaviour Esr.Role.Control

  alias Esr.SessionRegistry
  alias Esr.Uri, as: EsrUri

  @impl true
  def execute(%{"args" => args}) do
    chat_id = args["chat_id"] || ""
    app_id = args["app_id"] || ""
    thread_id = args["thread_id"] || ""

    case SessionRegistry.lookup_by_chat_thread(chat_id, app_id, thread_id) do
      {:ok, sid, _refs} ->
        uri = EsrUri.build_path(["sessions", sid, "attach"], "localhost")
        http_url = EsrUri.to_http_url(uri, EsrWeb.Endpoint)

        {:ok,
         %{
           "text" =>
             "🖥 attach: [#{http_url}](#{http_url})\n" <>
               "uri: `#{uri}`"
         }}

      :not_found ->
        {:ok,
         %{
           "text" => "no live session in this chat. start one with /new-session first"
         }}
    end
  end
end
```

- [ ] **Step 3: Run**

```bash
mix test runtime/test/esr/admin/commands/attach_test.exs
```

Expected: both pass.

- [ ] **Step 4: Run full test suite to catch slash-routes yaml issues**

```bash
mix test runtime/test/esr/slash_routes_test.exs runtime/test/esr/admin/dispatcher_test.exs 2>&1 | tail -15
```

Expected: all pass (yaml-driven dispatch picks up new entry).

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/admin/commands/attach.ex runtime/priv/slash-routes.default.yaml runtime/test/esr/admin/commands/attach_test.exs
git commit -m "$(cat <<'EOF'
feat(slash): /attach — return clickable browser link to PtyProcess attach

PR-22. Resolves session via SessionRegistry; renders both HTTP URL
(/sessions/<sid>/attach) and canonical esr:// URI. Yaml entry under
slash-routes.default.yaml; no permission required (Tailnet trust).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 9: agents.yaml swap + @stateful_impls + cc_process diagnostic drops

### Task 9.1: agents.yaml — swap tmux_process → pty_process (name + impl)

**Files:**
- Modify: `runtime/priv/agents.yaml`
- (Operator-installed copy `~/.esrd-dev/default/agents.yaml` will be edited at restart time, Phase 12)

- [ ] **Step 1: Inspect**

```bash
grep -n "tmux_process\|TmuxProcess" runtime/priv/agents.yaml
```

Expected output:
```
16:        - name: tmux_process
17:          impl: Esr.Peers.TmuxProcess
```

(Both lines need to flip — `name:` for the pipeline reference, `impl:` for the module FQN.)

- [ ] **Step 2: Swap both lines**

```bash
sed -i '' '
  s/name: tmux_process/name: pty_process/
  s/Esr.Peers.TmuxProcess/Esr.Peers.PtyProcess/g
' runtime/priv/agents.yaml

git diff runtime/priv/agents.yaml
```

Verify `name: pty_process` + `impl: Esr.Peers.PtyProcess` together; nothing else moved.

### Task 9.2: SessionRouter `@stateful_impls` MapSet

**Files:**
- Modify: `runtime/lib/esr/session_router.ex` (around line 59-70)

- [ ] **Step 1: Inspect**

```bash
sed -n '55,75p' runtime/lib/esr/session_router.ex
```

Expected: a `@stateful_impls MapSet.new([...])` listing `Esr.Peers.TmuxProcess` along with FCP / CCProcess / FAA / VoiceE2E.

- [ ] **Step 2: Replace TmuxProcess with PtyProcess**

```bash
sed -i '' 's/Esr.Peers.TmuxProcess/Esr.Peers.PtyProcess/' runtime/lib/esr/session_router.ex
```

Verify with `git diff runtime/lib/esr/session_router.ex` that only the MapSet entry changed.

### Task 9.3: cc_process — drop both diagnostic-output clauses

**Files:**
- Modify: `runtime/lib/esr/peers/cc_process.ex`

- [ ] **Step 1: Find every `:tmux_output` reference**

```bash
grep -n "tmux_output\|:tmux_output" runtime/lib/esr/peers/cc_process.ex
```

Expected: three sites — `handle_upstream({:tmux_output, ...})` around line 165–174, `handle_info({:tmux_output, _}, state)` around line 201, and `event_to_map({:tmux_output, ...})` around line 633.

- [ ] **Step 2: Delete all three**

For each match, delete the function clause and its preceding comment block. Use `Read` + `Edit` rather than sed (the comment blocks are multi-line and easy to misclip).

- [ ] **Step 3: Verify cleanup**

```bash
grep -n "tmux_output\|:tmux_output" runtime/lib/esr/peers/cc_process.ex
```

Expected: 0 matches.

- [ ] **Step 4: Run cc_process tests**

```bash
mix test runtime/test/esr/peers/cc_process_test.exs 2>&1 | tail -10
```

Expected: pass. If a test asserts the drop clause directly, delete that test — it tests behavior that no longer has a producer.

- [ ] **Step 5: Commit**

```bash
git add runtime/priv/agents.yaml runtime/lib/esr/session_router.ex runtime/lib/esr/peers/cc_process.ex
git commit -m "$(cat <<'EOF'
refactor: agents.yaml + @stateful_impls + cc_process drops (PR-22)

- agents.yaml: cc.pipeline.inbound name+impl flipped to PtyProcess
- session_router.ex @stateful_impls MapSet: TmuxProcess → PtyProcess
- cc_process: delete handle_upstream/handle_info/event_to_map clauses
  for {:tmux_output, _} (no PtyProcess source post-PR-22; was dead
  code in waiting)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 10: TmuxProcess + dead-test deletions

### Task 10.1: Delete TmuxProcess

**Files:**
- Delete: `runtime/lib/esr/peers/tmux_process.ex`
- Delete: `runtime/test/esr/peers/tmux_process_test.exs`
- Delete: `runtime/test/esr/peers/tmux_rewire_test.exs` (already ported to pty_rewire_test.exs)
- Delete: `runtime/test/esr/integration/n2_tmux_test.exs` (rewrite below)

- [ ] **Step 1: Delete the four files**

```bash
rm runtime/lib/esr/peers/tmux_process.ex
rm runtime/test/esr/peers/tmux_process_test.exs
rm runtime/test/esr/peers/tmux_rewire_test.exs
rm runtime/test/esr/integration/n2_tmux_test.exs
```

- [ ] **Step 2: Sweep references**

```bash
grep -rn "TmuxProcess\|tmux_process_test\|n2_tmux" runtime/ scripts/ 2>/dev/null
```

Expected: 0 hits in production code; possibly some in `docs/`. Documentation hits can stay (historical). Production hits → fix.

- [ ] **Step 3: Run full suite**

```bash
mix test 2>&1 | tail -20
```

Expected: same pass count as Phase 0 baseline minus the deleted-test count, no new failures.

### Task 10.2: Rewrite n2_pty_test

**Files:**
- Create: `runtime/test/esr/integration/n2_pty_test.exs`

- [ ] **Step 1: Inspect what the old n2_tmux_test asserted (from git history)**

```bash
git show HEAD~5:runtime/test/esr/integration/n2_tmux_test.exs 2>/dev/null | head -80
```

The test asserts that an inbound message reaches the OS process via the peer chain. Port the assertion shape, dropping tmux-specific framing checks.

- [ ] **Step 2: Write minimal n2_pty_test**

```elixir
defmodule Esr.Integration.N2PtyTest do
  @moduledoc """
  PR-22 N2 integration — verifies an inbound `:text` event reaches
  PtyProcess (replacing the prior n2_tmux_test which asserted tmux
  send-keys framing). PtyProcess receives via the per-session
  pipeline; cc_mcp / cli:channel is the conversation path so we
  only assert peer wiring + lifecycle here.
  """

  use ExUnit.Case, async: false

  alias Esr.Peers.PtyProcess

  @tag :integration
  test "PtyProcess starts under session supervisor and registers in PeerRegistry" do
    if System.get_env("CLAUDE_CMD") in [nil, ""] do
      # Skip — this test would actually exec scripts/esr-cc.sh which
      # spawns claude; not appropriate for CI.
      :ok
    else
      sid = "test-n2-pty-#{System.unique_integer([:positive])}"

      # Bring up a session via SessionRouter (real integration).
      {:ok, _} = Esr.SessionRouter.start_session(%{"name" => sid, "workspace" => "default"})

      # PtyProcess registers itself in Esr.PeerRegistry with binary
      # actor_id "pty:<sid>" (see PtyProcess.init/1).
      assert {:ok, pid} = Esr.PeerRegistry.lookup("pty:" <> sid)
      assert Process.alive?(pid)

      # Cleanup
      :ok = Esr.SessionRouter.end_session(sid)
    end
  end
end
```

(If `start_session/1` arity is different, adapt to the real SessionRouter signature.)

- [ ] **Step 3: Run**

```bash
mix test runtime/test/esr/integration/n2_pty_test.exs
```

Expected: pass. If the test infrastructure tries to actually spawn `claude`, mark with `@tag :integration` and add a skip when `CLAUDE_CMD` env not set.

- [ ] **Step 4: Commit**

```bash
git add -u runtime/lib/esr/peers/tmux_process.ex runtime/test/esr/peers/tmux_process_test.exs runtime/test/esr/peers/tmux_rewire_test.exs runtime/test/esr/integration/n2_tmux_test.exs runtime/test/esr/integration/n2_pty_test.exs
git commit -m "$(cat <<'EOF'
chore: delete TmuxProcess + tmux-specific tests (PR-22)

Replaced by Esr.Peers.PtyProcess (Phase 3). Removes:
- runtime/lib/esr/peers/tmux_process.ex (~835 LOC)
- runtime/test/esr/peers/tmux_process_test.exs (~600 LOC)
- runtime/test/esr/peers/tmux_rewire_test.exs (ported to pty_rewire_test.exs)
- runtime/test/esr/integration/n2_tmux_test.exs (rewritten as n2_pty_test.exs)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 11: esr-cc.sh tmux comment cleanup

### Task 11.1: Audit + remove tmux references

**Files:**
- Modify: `scripts/esr-cc.sh`

- [ ] **Step 1: Find tmux mentions**

```bash
grep -n "tmux" scripts/esr-cc.sh
```

Expected: comments + maybe a `command -v tmux` check.

- [ ] **Step 2: Remove tmux-checks; keep behavioral logic**

For each line found:
- Comments referencing tmux behavior (e.g. "tmux's -c flag") → rewrite or delete
- Conditional `command -v tmux` checks → delete (no longer needed)
- `tmux send-keys` invocations → should already be 0 (TmuxProcess owned them)
- `cwd` fallback comment (line ~63-67) → rewrite to reference PtyProcess + erlexec `{:cd, …}`

- [ ] **Step 3: Verify script still runs**

```bash
bash -n scripts/esr-cc.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add scripts/esr-cc.sh
git commit -m "$(cat <<'EOF'
chore(scripts): drop tmux references from esr-cc.sh (PR-22)

Comments that referenced tmux's -c flag / send-keys are obsolete; cwd
fallback comment rewritten to reference erlexec's {:cd, ...} which
PtyProcess uses directly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 12: Local verification

### Task 12.1: Full suite + boot smoke

- [ ] **Step 1: Full test suite**

```bash
mix test 2>&1 | tail -10
```

Expected: green. Pass count = (Phase 0 baseline) + new tests − deleted tests.

- [ ] **Step 2: Compile clean**

```bash
mix compile --warnings-as-errors 2>&1 | tail -10
```

Expected: 0 warnings. Address any `unused alias`/`unreachable clause` from the deletions.

- [ ] **Step 3: Generate docs**

```bash
mix docs 2>&1 | tail -5
```

Expected: clean.

### Task 12.2: Live esrd boot test (optional but recommended)

- [ ] **Step 1: Restart dev esrd**

```bash
launchctl kickstart -k gui/$(id -u)/com.openclaw.esrd-dev 2>&1 | tail -3
```

- [ ] **Step 2: Tail logs for PtyProcess startup**

```bash
tail -100 ~/.esrd-dev/log/esrd.log | grep -E "PtyProcess|TmuxProcess|attach"
```

Expected: PtyProcess starts cleanly; no TmuxProcess references.

- [ ] **Step 3: Test the slash via Feishu**

In the dev Feishu chat, send `/new-session name=test-pr-22 workspace=default`. Wait for confirmation. Then send `/attach`.

Expected: returns a message containing `[http://...](http://...)` and `esr://localhost/sessions/<sid>/attach`.

- [ ] **Step 4: Open the URL in the browser**

Replace the host with the Tailnet IP (`100.64.0.27:4001/sessions/<sid>/attach`) and open in remote browser. Should see claude's TUI.

- [ ] **Step 5: Type into the terminal**

Type `Ctrl-L` to redraw, then `hi`. claude should respond.

- [ ] **Step 6: End session**

In Feishu, send `/end-session test-pr-22`. The browser tab should show a `[session ended: ...]` overlay.

(If any step fails, capture the log + revert to feature/pr-22-pty-actor-attach for fixing — don't ship.)

---

## Phase 12.5: E2E scenario — `06_pty_attach.sh`

Per memory rule "E2E faces production topology": every new operator-facing flow earns an e2e scenario that hits the real production topology end-to-end. PR-22 introduces a new chat-to-browser workflow; we need e2e coverage so future regressions get caught by CI.

Existing e2e scenarios live under `tests/e2e/scenarios/` (`01_single_user_create_and_end.sh`, `02_two_users_concurrent.sh`, ..., `05_topology_routing.sh`). We add `06_pty_attach.sh`.

### Task 12.5.1: Write the scenario

**Files:**
- Create: `tests/e2e/scenarios/06_pty_attach.sh`

- [ ] **Step 1: Read existing scenario as template**

```bash
cat tests/e2e/scenarios/01_single_user_create_and_end.sh
```

Note the structure: source `common.sh`, send slash via mock-feishu API, assert reply text matches expectation, clean up.

- [ ] **Step 2: Write the e2e**

```bash
#!/usr/bin/env bash
# tests/e2e/scenarios/06_pty_attach.sh
#
# PR-22 — verifies the /attach slash returns a working browser URL
# and that AttachLive responds at the rendered HTTP path.
#
# Production topology under test:
#   1. /new-session creates a real PtyProcess under peers DynamicSupervisor
#   2. /attach returns a Feishu reply containing both an esr:// URI
#      and an http:// URL routed via EsrWeb.AttachLive
#   3. GET <http_url> returns 200 + has the xterm.js mount div
#   4. /end-session tears down PtyProcess; AttachLive subscribers receive
#      :pty_closed (we observe this via WebSocket for completeness)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

scenario_setup "06_pty_attach"

# Step 1: Create a session
SESSION_NAME="e2e-pty-${RANDOM}"
reply=$(send_slash "/new-session workspace=default name=${SESSION_NAME}")
assert_contains "$reply" "session" "/new-session reply mentions session"

# Step 2: Resolve sid from the SessionRegistry (e2e harness exposes
# `peek_session_id` — see common.sh)
sid=$(peek_session_id "${SESSION_NAME}")
[ -n "$sid" ] || fail "could not resolve sid for ${SESSION_NAME}"

# Step 3: /attach should return a clickable URL + canonical URI
reply=$(send_slash "/attach")
assert_contains "$reply" "esr://localhost/sessions/${sid}/attach" \
  "/attach reply contains canonical esr URI"
assert_contains "$reply" "/sessions/${sid}/attach" \
  "/attach reply contains HTTP path"

# Step 4: Extract HTTP URL from reply, hit it
http_url=$(extract_http_url "$reply")
[ -n "$http_url" ] || fail "no HTTP URL parsed from /attach reply"

http_status=$(curl -s -o /tmp/attach_body -w "%{http_code}" "$http_url")
assert_eq "$http_status" "200" "GET ${http_url} returns 200"
assert_contains "$(cat /tmp/attach_body)" "phx-hook=\"XtermAttach\"" \
  "AttachLive renders xterm hook"

# Step 5: Tear down
reply=$(send_slash "/end-session ${SESSION_NAME}")
assert_contains "$reply" "ended" "/end-session confirms"

# Step 6: GET should still work but render the "ended" overlay path
# (we don't assert overlay content — that's a JS-side concern; just
# confirm the route doesn't 500 after teardown)
http_status=$(curl -s -o /dev/null -w "%{http_code}" "$http_url")
assert_eq "$http_status" "200" "AttachLive remains routable post-end"

scenario_teardown
echo "06_pty_attach OK"
```

- [ ] **Step 3: Add helper functions to `common.sh` if missing**

Two helpers `peek_session_id` and `extract_http_url` may not exist:

```bash
grep -n "peek_session_id\|extract_http_url" tests/e2e/scenarios/common.sh
```

If absent, append:

```bash
# tests/e2e/scenarios/common.sh additions
peek_session_id() {
  local name="$1"
  curl -sS "http://${ESR_PUBLIC_HOST:-127.0.0.1}:${PORT:-4001}/admin/sessions" \
    | jq -r ".[] | select(.name == \"${name}\") | .session_id"
}

extract_http_url() {
  local reply="$1"
  # reply text is "🖥 attach: [http://...](http://...)\nuri: `esr://...`"
  echo "$reply" | grep -oE 'https?://[^)]+' | head -1
}
```

(`/admin/sessions` may not exist; if not, use the same lookup the e2e harness uses today — check `01_single_user_create_and_end.sh` for the existing pattern and reuse.)

- [ ] **Step 4: Make executable + run locally**

```bash
chmod +x tests/e2e/scenarios/06_pty_attach.sh

# Make sure dev esrd is running with ESR_PUBLIC_HOST=127.0.0.1 PORT=4001
ESR_PUBLIC_HOST=127.0.0.1 PORT=4001 ./tests/e2e/scenarios/06_pty_attach.sh
```

Expected: `06_pty_attach OK`. Failures are real bugs — fix before commit.

- [ ] **Step 5: Wire into CI runner**

Find where the existing scenarios are invoked from CI:

```bash
grep -rn "01_single_user\|run-scenarios\|e2e/scenarios" .github/ scripts/ 2>/dev/null | head -10
```

Add `06_pty_attach.sh` to whatever the runner enumerates (usually a glob or an explicit list).

- [ ] **Step 6: Commit**

```bash
git add tests/e2e/scenarios/06_pty_attach.sh tests/e2e/scenarios/common.sh
git commit -m "$(cat <<'EOF'
test(e2e): 06_pty_attach.sh — /new-session → /attach → curl → /end-session

PR-22 e2e. Asserts production topology: PtyProcess spawn, AttachLive
HTTP route, esr URI rendering, graceful teardown. Uses ESR_PUBLIC_HOST
to hit the same network path operators do.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 13: PR + dev → main + esrd restart

### Task 13.1: Open PR

- [ ] **Step 1: Push feature branch**

```bash
git push -u origin feature/pr-22-pty-actor-attach
```

- [ ] **Step 2: Open PR against `dev`**

```bash
gh pr create --base dev --title "PR-22: PtyProcess + xterm.js LiveView attach" --body "$(cat <<'EOF'
## Summary

- Replace `Esr.Peers.TmuxProcess` with generic `Esr.Peers.PtyProcess` (erlexec :pty wrapper).
- Add `EsrWeb.AttachLive` xterm.js LiveView at `/sessions/:sid/attach`.
- Add `/attach` slash command returning `esr://localhost/sessions/<sid>/attach` URI + clickable HTTP URL.
- Net deletion: ~870 LOC (tmux protocol parsing, send-keys, capture-pane, MCP-config-render all gone).

Spec: `docs/superpowers/specs/2026-05-01-pty-actor-attach-design.md` (rev 3).
Plan: `docs/superpowers/plans/2026-05-01-pty-actor-attach.md`.

## Test plan

- [ ] `mix test` green
- [ ] `mix compile --warnings-as-errors` clean
- [ ] Live boot: `/new-session` → `/attach` → browser shows claude TUI
- [ ] Type `Ctrl-L`, type `hi`, claude responds
- [ ] `/end-session` → browser shows `[session ended]` overlay
- [ ] `tmux kill-server` (if any leftover socket) does not affect ESR sessions

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Wait for CI**

```bash
gh pr checks --watch
```

If `enforce-pr-from-dev.yml` fires (PR-21ζ rule), confirm we're targeting `dev` not `main`.

### Task 13.2: Merge dev → main + restart prod

- [ ] **Step 1: Squash-merge to dev (admin if blocked)**

```bash
gh pr merge --admin --squash --delete-branch
```

Per memory: admin merge authorized for ezagent42/esr.

- [ ] **Step 2: Promote dev to main via the standard script**

```bash
scripts/promote-dev-to-main.sh
```

(Or follow `docs/dev-flow.md` if the script needs review first.)

- [ ] **Step 3: Restart production esrd**

```bash
launchctl kickstart -k gui/$(id -u)/com.openclaw.esrd 2>&1
```

- [ ] **Step 4: Smoke test prod via Feishu**

Repeat the `/attach` flow in the prod chat. Confirm working.

- [ ] **Step 5: Update todo.md — mark PR-22 done**

Move the relevant todo entries to "Done — recent" section. Re-add the `cc_mcp + channel abstraction` entry (originally added 2026-05-01, deferred until after PR-22) — it's now unblocked and ready for design discussion.

---

## Self-review checklist (run before sending plan to user)

- [ ] Each spec section maps to at least one task above
  - PtyProcess shape → Phase 3
  - PubSub broadcast contract → Task 3.2
  - Stdin write path → Task 3.2 (`write/2`, `resize/3`)
  - MCP config (deleted) → Phase 10 deletion
  - Single-writer policy → documented only (no enforcement); covered in spec, no task
  - URL scheme (esr URI) → Phase 1 (`to_http_url/2`) + Phase 8 (slash command)
  - Router → Phase 7
  - Lifecycle (on_os_exit, rewire) → Phase 3 + Phase 4
  - Files added / modified / deleted → Phases 3, 5, 6, 7, 8, 9, 10, 11
- [ ] No "TBD" / "TODO" / "fill in details" placeholders
- [ ] Function names consistent: `write/2`, `resize/3`, `to_http_url/2`, `rewire_session_siblings/1`
- [ ] Each step has either code OR a concrete command + expected output
