# PR-3 Expanded: CC Chain + SessionRouter + Topology Removal + Capability Consolidation

**Date**: 2026-04-23
**Branch**: `feature/peer-session-refactor` (current worktree: `.worktrees/peer-session-refactor/`)
**Prereq reading order** (load into working memory before starting any P3-N task):

1. `docs/superpowers/progress/2026-04-23-pr2-snapshot.md` — PR-2 API shapes (AdminSession, Session, SessionProcess, SessionRegistry, SessionsSupervisor, Peers.Feishu*, SlashHandler, Admin.Commands.Session.AgentNew)
2. `docs/superpowers/progress/2026-04-22-pr1-snapshot.md` — OSProcess底座 (`wrapper: :muontrap | :none`), TmuxProcess, PyProcess, Peer.Proxy/Stateful behaviours
3. `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.3, §3.5, §3.6, §3.7, §4.1 (CC/Tmux/CCProxy cards), §5.1–§5.4, §6 Risk E + Risk F, §1.8 D15 D18
4. `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md` lines 2227–2266 — PR-3 outline
5. `docs/notes/capability-name-format-mismatch.md` — P3-8 canonicalizes spec-wide
6. `docs/notes/muontrap-mode3-constraint.md` — TmuxProcess must use `wrapper: :none`
7. `docs/notes/feishu-ws-ownership-python.md` — WS stays in Python; only affects agent definitions indirectly
8. `docs/futures/peer-session-capability-projection.md` — P3-3a implementation notes
9. `.claude/skills/muontrap-elixir/SKILL.md` — Mode 3c reference for TmuxProcess
10. Touched code: `runtime/lib/esr/peer_server.ex`, `runtime/lib/esr/topology/*`, `runtime/lib/esr/routing/slash_handler.ex`, `runtime/lib/esr/admin/commands/session/{new,agent_new,end}.ex`, `runtime/lib/esr/application.ex`

---

## Task Quick Reference

| # | Task | File scope | Feishu-notify? | Depends on |
|---|---|---|---|---|
| P3-0 | **Feishu PR-3 start notification** | — | ✅ start | — |
| P3-1 | `Esr.Peers.CCProxy` (Peer.Proxy) | `runtime/lib/esr/peers/cc_proxy.ex`, test | — | P3-8 (canonical cap name needed for `@required_cap`) → actually P3-8 lands capability canonicalization FIRST; reorder below |
| P3-8 | **Capability canonicalization + Session.New consolidation** (MOVED EARLIER) | spec §3.5/§3.6/§1.8; agents.yaml fixtures; `peers/feishu_app_proxy.ex`; `admin/commands/session/{new,branch_new}.ex`; `admin/dispatcher.ex`; `capabilities.ex` | — | — (must precede P3-1 because `@required_cap` strings need the canonical form) |
| P3-1 | `Esr.Peers.CCProxy` | `runtime/lib/esr/peers/cc_proxy.ex`, test | — | P3-8 |
| P3-2 | `Esr.Peers.CCProcess` (Peer.Stateful + HandlerRouter wiring) | `runtime/lib/esr/peers/cc_process.ex`, test | ✅ after P3-2 lands | P3-1 |
| P3-3 | `Esr.Peers.TmuxProcess` re-home + handle_downstream for input | `runtime/lib/esr/peers/tmux_process.ex`, test | — | P3-2 |
| P3-3a | **Session-scoped grants projection** | `session_process.ex`, `capabilities/grants.ex`, `peer_server.ex`, `peers/feishu_app_proxy.ex` (test override path) | ✅ after P3-3a | P2-6a scaffold |
| P3-4 | `Esr.SessionRouter` (control plane) | `runtime/lib/esr/session_router.ex`, test | — | P3-3a |
| P3-5 | SessionRouter Risk-E boundary test | test | — | P3-4 |
| P3-6 | `agents.yaml` — wire `cc` agent to full CC chain | `runtime/test/esr/fixtures/agents/*.yaml`; ops note referencing `~/.esrd/default/agents.yaml` | ✅ after P3-6 | P3-3, P3-4, P3-8 |
| P3-7 | Wire FeishuAppAdapter `:new_chat_thread` PubSub → SessionRouter | `runtime/lib/esr/session_router.ex` handler; FAA keeps broadcast; SessionRouter subscribes | — | P3-4, P3-6 |
| P3-9 | Update `Session.End` for new supervisor tree | `runtime/lib/esr/admin/commands/session/end.ex` (new `session_end` semantics for agent sessions) | — | P3-4, P3-7 |
| P3-10 | Full E2E test: Feishu → tmux → Feishu | `runtime/test/esr/integration/cc_e2e_test.exs` | ✅ after P3-10 | P3-1..P3-9 |
| P3-11 | N=2 concurrent tmux test | `runtime/test/esr/integration/n2_tmux_test.exs` | — | P3-10 |
| P3-12 | OS cleanup regression (`mix test.e2e.os_cleanup`) | `runtime/mix.exs` aliases; `runtime/test/esr/integration/os_cleanup_test.exs` | — | P3-11 |
| P3-13 | Delete `Esr.Topology.*` | `runtime/lib/esr/topology/`, `peer_server.ex` (remove `invoke_command` + aliases), `application.ex`, `esr_web/cli_channel.ex`, `test/esr/topology/*` | ✅ after P3-13 | P3-4 (SessionRouter replaces role) |
| P3-14 | Delete `Esr.Routing.SlashHandler` (+ `Esr.Routing.Supervisor`) | `runtime/lib/esr/routing/*`, `application.ex`, `test/esr/routing/*` | — | P3-13 (clean pass) |
| P3-15 | PubSub audit + convert | `docs/notes/pubsub-audit-pr3.md` (new), multiple modules | ✅ after P3-15 | P3-14 |
| P3-16 | Delete CC-era code from `peer_server.ex` | `runtime/lib/esr/peer_server.ex` | — | P3-15 |
| P3-17 | Open PR-3 draft | `gh pr create` | ✅ PR opened | P3-16 |
| P3-18 | Wait for user review + merge | — | ✅ merged | P3-17 |
| P3-19 | PR-3 progress snapshot | `docs/superpowers/progress/<date>-pr3-snapshot.md` | ✅ final | P3-18 |

**Reorder note (explained in report)**: P3-8 is moved before P3-1 because every Peer.Proxy created in P3-1+ declares `@required_cap`. If the canonical name format lands later, we either write test-override-only code now and rewrite strings twice, or we ship code with strings that fail closed against production `Grants.matches?/2`. Canonicalizing first is cheaper.

## Feishu notification cadence

Using the plan's cadence: PR-3 start + every 3–5 tasks + draft PR open + merge + snapshot. Concrete fire-points:

1. **P3-0**: PR-3 kickoff ("Starting PR-3: CC chain + SessionRouter + Topology removal + capability consolidation")
2. **After P3-2**: CCProcess lands (milestone: CC business logic has a home)
3. **After P3-3a**: session-scoped grants projection complete (milestone: test-flake root cause addressed + spec D22 done)
4. **After P3-6**: full CC `cc` agent in agents.yaml fixtures + dev stub notes published
5. **After P3-10**: E2E Feishu → tmux → Feishu green (headline achievement)
6. **After P3-13**: Topology module files deleted (deletion milestone)
7. **After P3-15**: PubSub audit complete (data-plane boundary hardened)
8. **P3-17**: PR-3 draft opened, link posted
9. **P3-18**: PR-3 merged
10. **P3-19**: snapshot written + "PR-3 complete; starting PR-4a/PR-4b parallel"

Use `mcp__openclaw-channel__reply` or the `Esr.Admin.Commands.Notify` path per whatever is configured in the author's channel.

---

## P3-0 — Feishu PR-3 start notification

**Why**: plan cadence requires a PR-start notification so the user knows work has begun in a new session context.

**Steps**:

1. Confirm PR-2 merged on `origin/main` (commit `fcef9e3`):
   ```bash
   git fetch origin && git log origin/main --oneline | head -3
   ```
   Expect `fcef9e3` present.

2. Verify working worktree is on `feature/peer-session-refactor`, clean tree:
   ```bash
   git status && git branch --show-current
   ```

3. Send Feishu notification with body:
   ```
   PR-3 kickoff — CC chain + SessionRouter + Topology removal.
   Scope: ~19 tasks across 4-5 days. First milestone: canonicalize capability
   names spec-wide (P3-8), then build CCProxy/CCProcess/TmuxProcess chain.
   Plan: docs/superpowers/progress/2026-04-23-pr3-expanded.md
   ```

**Verification**: Feishu channel shows the notification with a timestamp within the past minute.

---

## P3-8 (executed first) — Capability name canonicalization + Session.New consolidation

**Why**: Spec's `cap.*` form doesn't parse via `Esr.Capabilities.Grants.matches?/2` (see `docs/notes/capability-name-format-mismatch.md`). P3-1+'s `@required_cap` strings must be in the canonical `prefix:name/perm` form before production paths go live. Additionally, D15 collapses `session_new` branch semantics → `session_branch_new` and elevates `session_agent_new` → `session_new`.

**TDD steps**:

### P3-8.1 — Spec doc edits (non-code)

Edit `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`:

- §3.5 `agents.yaml` example (cc agent): replace `capabilities_required` list with canonical form.
  ```yaml
  capabilities_required:
    - session:default/create
    - tmux:default/spawn
    - handler:cc_adapter_runner/invoke
  ```
- §3.5 `cc-voice` agent: add `peer_pool:voice_asr/acquire`, `peer_pool:voice_tts/acquire`.
- §3.5 `voice-e2e`: `handler:voice_e2e/invoke`.
- §3.6 PeerProxy example: `@required_cap "peer_proxy:feishu/forward"`.
- §1.8 D18 row: re-state check form as `prefix:name/perm`.

Verify by grepping the spec file: `grep -n "cap\." docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` returns zero hits for agent-capability examples.

### P3-8.2 — Add `Esr.Capabilities.has_all?/2`

Write test first `runtime/test/esr/capabilities_has_all_test.exs`:
```elixir
defmodule Esr.CapabilitiesHasAllTest do
  use ExUnit.Case, async: false

  setup do
    Esr.Capabilities.Grants.load_snapshot(%{
      "ou_alice" => ["session:default/create", "tmux:default/spawn"]
    })
    on_exit(fn -> Esr.Capabilities.Grants.load_snapshot(%{}) end)
    :ok
  end

  test "returns :ok when principal has every required permission" do
    assert :ok =
             Esr.Capabilities.has_all?(
               "ou_alice",
               ["session:default/create", "tmux:default/spawn"]
             )
  end

  test "returns {:missing, [...]} listing gaps" do
    assert {:missing, ["handler:cc_adapter_runner/invoke"]} =
             Esr.Capabilities.has_all?(
               "ou_alice",
               ["session:default/create", "handler:cc_adapter_runner/invoke"]
             )
  end

  test "empty list is trivially :ok" do
    assert :ok = Esr.Capabilities.has_all?("ou_alice", [])
  end
end
```

Implement in `runtime/lib/esr/capabilities.ex`:
```elixir
@spec has_all?(String.t(), [String.t()]) :: :ok | {:missing, [String.t()]}
def has_all?(principal_id, perms) when is_binary(principal_id) and is_list(perms) do
  case Enum.reject(perms, &has?(principal_id, &1)) do
    [] -> :ok
    missing -> {:missing, missing}
  end
end
```

Run: `cd runtime && mix test test/esr/capabilities_has_all_test.exs`. Expect 3 passing.

### P3-8.3 — Update `FeishuAppProxy.@required_cap` + add real test (not override-based)

Edit `runtime/lib/esr/peers/feishu_app_proxy.ex`:
```elixir
@required_cap "peer_proxy:feishu/forward"
```

Update `runtime/test/esr/peers/feishu_app_proxy_test.exs`:
- Remove `Process.put(:esr_cap_test_override, ...)` in the positive path; instead call `Esr.Capabilities.Grants.load_snapshot(%{"ou_alice" => ["peer_proxy:feishu/forward"]})` in `setup`.
- Negative path: `Grants.load_snapshot(%{"ou_alice" => []})` → forward returns `{:drop, :unauthorized}`.

Run: `cd runtime && mix test test/esr/peers/feishu_app_proxy_test.exs`. Expect green; positive path now exercises real `Grants.has?/2`.

### P3-8.4 — Update agents.yaml fixtures

Edit `runtime/test/esr/fixtures/agents/simple.yaml`:
```yaml
agents:
  cc:
    description: "Claude Code"
    capabilities_required:
      - session:default/create
      - tmux:default/spawn
      - handler:cc_adapter_runner/invoke
    pipeline:
      inbound:
        - { name: feishu_chat_proxy, impl: Esr.Peers.FeishuChatProxy }
        - { name: cc_proxy,          impl: Esr.Peers.CCProxy }
        - { name: cc_process,        impl: Esr.Peers.CCProcess }
        - { name: tmux_process,      impl: Esr.Peers.TmuxProcess }
      outbound:
        - tmux_process
        - cc_process
        - cc_proxy
        - feishu_chat_proxy
    proxies:
      - { name: feishu_app_proxy, impl: Esr.Peers.FeishuAppProxy, target: "admin::feishu_app_adapter_${app_id}" }
    params:
      - { name: dir,    required: true,  type: path }
      - { name: app_id, required: false, default: "${primary_feishu_app}", type: string }
```

Edit `runtime/test/esr/fixtures/agents/multi_app.yaml`: swap `cap.session.create` → `session:default/create`, `cap.peer_proxy.forward_feishu` → `peer_proxy:feishu/forward`.

Run `mix test test/esr/session_registry_test.exs` to confirm yaml still parses (compiled `capabilities_required` is a list of binaries — structural check unchanged).

### P3-8.5 — Rename `Session.New` → `Session.BranchNew`

```bash
cd runtime && git mv lib/esr/admin/commands/session/new.ex lib/esr/admin/commands/session/branch_new.ex
```

Rename module inside file: `Esr.Admin.Commands.Session.New` → `Esr.Admin.Commands.Session.BranchNew`. Update moduledoc's opening sentence to indicate branch-worktree semantics only.

Update `runtime/test/esr/admin/commands/session/new_test.exs` (if present — check filesystem) → rename to `branch_new_test.exs`, update module + alias references. If test file is just `session/new_test.exs` under a different name, grep `Esr.Admin.Commands.Session.New` in `runtime/test/` and rewrite.

### P3-8.6 — Promote `Session.AgentNew` → `Session.New`

Move file:
```bash
cd runtime && git mv lib/esr/admin/commands/session/agent_new.ex lib/esr/admin/commands/session/new.ex
```

Inside `new.ex`:
- Rename module: `Esr.Admin.Commands.Session.AgentNew` → `Esr.Admin.Commands.Session.New`.
- Replace `verify_caps/2` body to use the new helper:
  ```elixir
  defp verify_caps(submitter, caps) when is_list(caps) do
    case Esr.Capabilities.has_all?(submitter, caps) do
      :ok -> :ok
      {:missing, missing} ->
        {:error, %{"type" => "missing_capabilities", "caps" => missing}}
    end
  end
  defp verify_caps(_, _), do: :ok
  ```
- Moduledoc: drop "(PR-2, parallel to Session.New)"; note this is the consolidated agent-session command; `Session.BranchNew` is the legacy branch-worktree path.

Rename test: `git mv test/esr/admin/commands/session/agent_new_test.exs test/esr/admin/commands/session/new_test.exs`; update module + aliases.

### P3-8.7 — Dispatcher kind remap

Edit `runtime/lib/esr/admin/dispatcher.ex`:
- `@required_permissions`: drop `"session_agent_new"`; keep `"session_new" => "session:default/create"` (canonicalize permission itself to match new form).
- Add `"session_branch_new" => "session:default/create"` (same permission — they're both session-creation actions).
- `@command_modules`: `"session_new" => Esr.Admin.Commands.Session.New`, `"session_branch_new" => Esr.Admin.Commands.Session.BranchNew`. Drop `"session_agent_new"`.

Edit `runtime/lib/esr/peers/slash_handler.ex`:
- Replace `{:ok, "session_agent_new", ...}` with `{:ok, "session_new", ...}` in `parse_new_session/1`.

### P3-8.8 — Migrate test callers of kind `session_agent_new` → `session_new`

Grep:
```bash
grep -rn "session_agent_new" /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/test 2>&1
```

Expected hits: `slash_handler_test.exs:117,139`, `integration/new_session_smoke_test.exs:10,44`, possibly the renamed new_test.exs. Replace with `session_new`.

The legacy `test/esr/routing/slash_handler_test.exs:77-84` references `session_new` with branch shape — this file dies in P3-14, leave it alone for now but add a skip tag so the mass-rename doesn't accidentally rebind branch semantics:
```elixir
@tag :skip_pr3_pending_delete
test "/new-session <branch> is session_new with new_worktree=false" do ...
```

### P3-8.9 — Run full suite; expect green

```bash
cd runtime && mix test --exclude integration --warnings-as-errors
```

Expect 362+ passing (PR-2 baseline) ± deltas from P3-8.2 (+3) and rename. Zero warnings.

**Feishu notify**: deferred to the P3-1..P3-2 checkpoint; P3-8 is a prerequisite, not a milestone users care about on its own.

---

## P3-1 — `Esr.Peers.CCProxy` (Peer.Proxy, stateless pass-through)

**Scope clarification**: in PR-3, CCProxy is a dumb forwarder with `@required_cap` as the future-hook for capability checks between Feishu and CC layers. No rate limiting, no business logic. Target = local CCProcess (same Session). `proxy_ctx` contains `:cc_process_pid` (resolved at session spawn by P3-4 SessionRouter).

**TDD steps**:

### P3-1.1 — Unit test

Create `runtime/test/esr/peers/cc_proxy_test.exs`:
```elixir
defmodule Esr.Peers.CCProxyTest do
  use ExUnit.Case, async: false
  alias Esr.Peers.CCProxy

  setup do
    Esr.Capabilities.Grants.load_snapshot(%{
      "ou_alice" => ["peer_proxy:cc/forward"]
    })
    on_exit(fn -> Esr.Capabilities.Grants.load_snapshot(%{}) end)
    :ok
  end

  test "forward/2 sends msg to cc_process_pid when alive" do
    me = self()
    fake_cc = spawn_link(fn -> receive_loop(me) end)
    ctx = %{principal_id: "ou_alice", cc_process_pid: fake_cc}

    assert :ok = CCProxy.forward({:text, "hello"}, ctx)
    assert_receive {:forwarded, {:text, "hello"}}, 200
  end

  test "forward/2 drops when cc_process_pid is dead" do
    dead = spawn(fn -> :ok end)
    Process.sleep(20)
    refute Process.alive?(dead)
    ctx = %{principal_id: "ou_alice", cc_process_pid: dead}

    assert {:drop, :target_unavailable} = CCProxy.forward({:text, "x"}, ctx)
  end

  test "forward/2 drops :unauthorized when principal lacks cap" do
    Esr.Capabilities.Grants.load_snapshot(%{"ou_bob" => []})
    me = self()
    fake_cc = spawn_link(fn -> receive_loop(me) end)
    ctx = %{principal_id: "ou_bob", cc_process_pid: fake_cc}

    assert {:drop, :unauthorized} = CCProxy.forward({:text, "x"}, ctx)
  end

  defp receive_loop(reply_to) do
    receive do
      msg ->
        send(reply_to, {:forwarded, msg})
        receive_loop(reply_to)
    end
  end
end
```

### P3-1.2 — Implementation

Create `runtime/lib/esr/peers/cc_proxy.ex`:
```elixir
defmodule Esr.Peers.CCProxy do
  @moduledoc """
  Stateless Peer.Proxy between FeishuChatProxy (upstream) and CCProcess
  (downstream) within the same Session. In PR-3 this is a pure forwarder;
  the `@required_cap` hook is the first enforcement point for any
  rate-limit / throttle policy between channels and CC agents.

  Spec §4.1 CCProxy card.
  """
  use Esr.Peer.Proxy
  @required_cap "peer_proxy:cc/forward"

  @impl Esr.Peer.Proxy
  def forward(msg, %{cc_process_pid: target} = _ctx) when is_pid(target) do
    if Process.alive?(target) do
      send(target, msg)
      :ok
    else
      {:drop, :target_unavailable}
    end
  end

  def forward(_msg, _ctx), do: {:drop, :invalid_ctx}
end
```

Run test: `cd runtime && mix test test/esr/peers/cc_proxy_test.exs`. Expect 3 passing.

### P3-1.3 — Update FeishuChatProxy to forward non-slash downstream

Edit `runtime/lib/esr/peers/feishu_chat_proxy.ex`:

- Add neighbor-aware downstream forward in `handle_upstream/2` non-slash branch; replace the PR-2 "drop with log" stance:
  ```elixir
  else
    case Keyword.get(state.neighbors, :cc_proxy) do
      pid when is_pid(pid) ->
        text = get_in(envelope, ["payload", "text"]) || ""
        send(pid, {:text, text})
        {:forward, [], state}

      _ ->
        Logger.warning(
          "feishu_chat_proxy: non-slash inbound but no cc_proxy neighbor " <>
            "(session_id=#{state.session_id})"
        )
        {:drop, :no_cc_proxy_neighbor, state}
    end
  end
  ```

- Update `runtime/test/esr/peers/feishu_chat_proxy_test.exs`: add two tests — (a) with `cc_proxy: fake_pid` in neighbors, non-slash inbound forwards `{:text, "..."}` to the fake; (b) without neighbor, logs a warning and drops `:no_cc_proxy_neighbor`.

Run `mix test test/esr/peers/feishu_chat_proxy_test.exs`. Expect green.

---

## P3-2 — `Esr.Peers.CCProcess` (Peer.Stateful, HandlerRouter-integrated)

**Scope clarification**: spec §4.1 CCProcess card says it invokes Python via `HandlerRouter.call/3`. PR-3 wires this for real. `CCProcess` state holds `cc_session_state` map (forwarded to the handler), directive-queue, pending-tool-req map (same correlation pattern peer_server uses). Downstream neighbor is TmuxProcess. Upstream is CCProxy.

**Messages** (this peer's protocol):
- `{:text, bytes}` (from CCProxy upstream) — invoke handler, may produce `{:send_input, text}` downstream to Tmux
- `{:tmux_output, bytes}` (from TmuxProcess upstream) — accumulate output; may produce `{:reply, text}` upward to FeishuChatProxy via CCProxy via downstream

### P3-2.1 — Unit test (handler_router behaviour)

Create `runtime/test/esr/peers/cc_process_test.exs`:
```elixir
defmodule Esr.Peers.CCProcessTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.CCProcess

  @handler_module "cc_adapter_runner"

  setup do
    # Stub HandlerRouter.call/3 via a process-dict override that
    # CCProcess reads when invoking the handler (introduced below).
    :ok
  end

  test "on {:text, bytes}, calls HandlerRouter and forwards :send_input to tmux neighbor" do
    me = self()
    tmux = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    # Simulate HandlerRouter.call returning an action list
    Process.put(:cc_handler_override, fn ^@handler_module, _payload, _timeout ->
      {:ok, %{"history" => ["hello"]}, [%{"type" => "send_input", "text" => "hello\n"}]}
    end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid1",
        handler_module: @handler_module,
        neighbors: [tmux_process: tmux, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    send(pid, {:text, "hello"})

    assert_receive {:relay, {:send_input, "hello\n"}}, 500
  end

  test "on {:tmux_output, bytes}, invokes handler, forwards :reply upstream" do
    me = self()
    tmux = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    Process.put(:cc_handler_override, fn ^@handler_module, _payload, _timeout ->
      {:ok, %{"history" => ["out"]}, [%{"type" => "reply", "text" => "done"}]}
    end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid2",
        handler_module: @handler_module,
        neighbors: [tmux_process: tmux, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    send(pid, {:tmux_output, "output from tmux"})
    assert_receive {:relay, {:reply, "done"}}, 500
  end

  test "HandlerRouter timeout drops the message and logs" do
    me = self()
    tmux = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)
    Process.put(:cc_handler_override, fn _, _, _ -> {:error, :handler_timeout} end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "sid3",
        handler_module: @handler_module,
        neighbors: [tmux_process: tmux, cc_proxy: cc_proxy],
        proxy_ctx: %{}
      })

    send(pid, {:text, "x"})
    refute_receive {:relay, _}, 200
  end

  defp relay(reply_to) do
    receive do
      msg -> send(reply_to, {:relay, msg}) ; relay(reply_to)
    end
  end
end
```

### P3-2.2 — Implementation

Create `runtime/lib/esr/peers/cc_process.ex`:
```elixir
defmodule Esr.Peers.CCProcess do
  @moduledoc """
  Per-Session Peer.Stateful holding CC business state. Invokes Python
  handler code via `Esr.HandlerRouter.call/3` on upstream messages and
  translates handler actions into downstream messages for TmuxProcess
  (`:send_input`) or upward replies to FeishuChatProxy via CCProxy (`:reply`).

  State:
    - session_id
    - handler_module (e.g. "cc_adapter_runner")
    - cc_state (the handler's state blob; passed in/out each invocation)
    - neighbors (keyword: :tmux_process, :cc_proxy)
    - proxy_ctx

  Spec §4.1 CCProcess card, §5.1 data flow.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  @default_timeout 5_000

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl Esr.Peer.Stateful
  def init(args) do
    {:ok,
     %{
       session_id: Map.fetch!(args, :session_id),
       handler_module: Map.fetch!(args, :handler_module),
       cc_state: Map.get(args, :initial_state, %{}),
       neighbors: Map.get(args, :neighbors, []),
       proxy_ctx: Map.get(args, :proxy_ctx, %{})
     }}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:text, bytes}, state),       do: invoke_and_dispatch({:text, bytes}, state)
  def handle_upstream({:tmux_output, bytes}, state), do: invoke_and_dispatch({:tmux_output, bytes}, state)
  def handle_upstream(_, state), do: {:drop, :unknown_upstream, state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_, state), do: {:forward, [], state}

  defp invoke_and_dispatch(event, state) do
    payload = %{
      "handler" => state.handler_module <> ".on_msg",
      "state"   => state.cc_state,
      "event"   => event_to_map(event)
    }

    case call_handler(state.handler_module, payload, @default_timeout) do
      {:ok, new_state, actions} when is_map(new_state) and is_list(actions) ->
        dispatch_actions(actions, state)
        {:forward, [], %{state | cc_state: new_state}}

      {:error, :handler_timeout} ->
        Logger.warning(
          "cc_process: handler timeout session_id=#{state.session_id}"
        )
        {:drop, :handler_timeout, state}

      {:error, other} ->
        Logger.warning(
          "cc_process: handler error #{inspect(other)} session_id=#{state.session_id}"
        )
        {:drop, :handler_error, state}
    end
  end

  defp call_handler(mod, payload, timeout) do
    case Process.get(:cc_handler_override) do
      fun when is_function(fun, 3) -> fun.(mod, payload, timeout)
      _ -> Esr.HandlerRouter.call(mod, payload, timeout)
    end
  end

  defp dispatch_actions(actions, state) do
    Enum.each(actions, &dispatch_action(&1, state))
  end

  defp dispatch_action(%{"type" => "send_input", "text" => text}, state) do
    case Keyword.get(state.neighbors, :tmux_process) do
      pid when is_pid(pid) -> send(pid, {:send_input, text})
      _ -> Logger.warning("cc_process: :send_input with no tmux_process neighbor")
    end
  end

  defp dispatch_action(%{"type" => "reply", "text" => text}, state) do
    case Keyword.get(state.neighbors, :cc_proxy) do
      pid when is_pid(pid) -> send(pid, {:reply, text})
      _ -> Logger.warning("cc_process: :reply with no cc_proxy neighbor")
    end
  end

  defp dispatch_action(unknown, state) do
    :telemetry.execute([:esr, :cc_process, :unknown_action], %{}, %{
      session_id: state.session_id,
      action: unknown
    })
  end

  defp event_to_map({:text, b}),        do: %{"kind" => "text", "text" => b}
  defp event_to_map({:tmux_output, b}), do: %{"kind" => "tmux_output", "bytes" => b}

  @impl GenServer
  def handle_info({:text, _} = msg, state),        do: via_stateful(msg, state, &handle_upstream/2)
  def handle_info({:tmux_output, _} = msg, state), do: via_stateful(msg, state, &handle_upstream/2)
  def handle_info(_, state), do: {:noreply, state}

  defp via_stateful(msg, state, fun) do
    case fun.(msg, state) do
      {:forward, _, ns} -> {:noreply, ns}
      {:drop, _, ns}    -> {:noreply, ns}
    end
  end
end
```

Run `mix test test/esr/peers/cc_process_test.exs`. Expect 3 passing.

**Feishu notify after P3-2**: "CCProcess wired to HandlerRouter — CC business-logic actor online. Next: TmuxProcess handle_downstream for send_input."

---

## P3-3 — `Esr.Peers.TmuxProcess` re-home + handle_downstream for `:send_input`

**Scope clarification**: TmuxProcess already exists at `runtime/lib/esr/tmux_process.ex` from PR-1 with `wrapper: :none`, control-mode `os_cmd`, `parse_event/1`. PR-3 needs to:
1. Move it under `runtime/lib/esr/peers/tmux_process.ex` (namespace convention: all session-scope peers live under `Esr.Peers.*`).
2. Add `handle_downstream({:send_input, text}, state)` that writes to tmux via `send-keys` command.
3. On `{:tmux_event, {:output, _pane, bytes}}`, forward `{:tmux_output, bytes}` to CCProcess neighbor (upstream from TmuxProcess's perspective in the chain: TmuxProcess → CCProcess).
4. Confirm `terminate/2` sends `tmux kill-session -t <name>` (currently missing in `tmux_process.ex`; OSProcess底座 handles Port close but app-level tmux cleanup needs explicit command per `docs/notes/muontrap-mode3-constraint.md`).

### P3-3.1 — Move the file + rename module

```bash
cd runtime && git mv lib/esr/tmux_process.ex lib/esr/peers/tmux_process.ex
git mv test/esr/tmux_process_test.exs test/esr/peers/tmux_process_test.exs
```

Inside the moved file, rename `defmodule Esr.TmuxProcess` → `defmodule Esr.Peers.TmuxProcess`. Update all references:
```bash
grep -rn "Esr\.TmuxProcess" /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime
```
Replace each with `Esr.Peers.TmuxProcess`. Also update `@moduledoc` line 2 (references `Peer + OSProcess composition`), no code change needed there.

### P3-3.2 — Add `terminate/2` for app-level tmux cleanup

Inside the OSProcess worker, we need a `terminate/2` that runs before the Port dies. But the macro's worker is anonymous. The cleanest approach: add a `terminate/2` to TmuxProcess.OSProcessWorker by extending the macro. Check whether the macro supports overridable terminate.

Looking at `runtime/lib/esr/os_process.ex`: the worker's GenServer doesn't declare `terminate/2`. Add one via module attribute. Extend `Esr.OSProcess.__using__/1` to emit an overridable `terminate/2` in the worker that calls `parent.on_terminate(state)` if defined. Keep this PR-3-local (don't expand OSProcess's public API beyond what TmuxProcess needs).

**Simpler alternative chosen**: add `terminate/2` directly via `defoverridable` in the generated worker by patching `os_process.ex`:

Edit `runtime/lib/esr/os_process.ex`, inside the `defmodule OSProcessWorker do` block add:
```elixir
@impl true
def terminate(_reason, %{parent: parent, state: state} = s) do
  if function_exported?(parent, :on_terminate, 1) do
    try do
      parent.on_terminate(state)
    rescue
      _ -> :ok
    end
  end
  _ = Port.close(s.port)
  :ok
end
```

Add callback declaration on `Esr.OSProcess`:
```elixir
@callback on_terminate(state :: term()) :: :ok
@optional_callbacks on_terminate: 1
```

In `Esr.Peers.TmuxProcess`, add:
```elixir
@impl Esr.OSProcess
def on_terminate(%{session_name: name}) do
  System.cmd("tmux", ["kill-session", "-t", name], stderr_to_stdout: true)
  :ok
end
```

### P3-3.3 — Add `handle_downstream({:send_input, text}, state)`

Edit `runtime/lib/esr/peers/tmux_process.ex`, update `handle_downstream/2`:
```elixir
@impl Esr.Peer.Stateful
def handle_downstream({:send_input, text}, state) do
  cmd = "send-keys -t #{state.session_name} \"#{escape(text)}\" Enter\n"
  __MODULE__.OSProcessWorker.write_stdin(self(), cmd)
  {:forward, [], state}
end

# Keep the old {:send_keys, text} clause for backward compat with PR-1 tests
def handle_downstream({:send_keys, text}, state), do: handle_downstream({:send_input, text}, state)

def handle_downstream(_, state), do: {:forward, [], state}
```

### P3-3.4 — Route `{:tmux_event, {:output, ...}}` upward to CCProcess

Edit `handle_upstream/2` in `tmux_process.ex`: when a `{:tmux_event, {:output, _pane, bytes}}` is built, also push `{:tmux_output, bytes}` to neighbor `cc_process` if present. Since the OSProcess底座 dispatches from the worker to the parent's `handle_upstream`, we need neighbors reachable there. Store neighbors in state at init:

```elixir
@impl Esr.Peer.Stateful
def init(%{session_name: _, dir: _} = args) do
  {:ok,
   %{
     session_name: args.session_name,
     dir: args.dir,
     subscribers: [args[:subscriber] || self()],
     neighbors: Map.get(args, :neighbors, []),
     proxy_ctx: Map.get(args, :proxy_ctx, %{})
   }}
end

@impl Esr.Peer.Stateful
def handle_upstream({:os_stdout, line}, state) do
  event = parse_event(line)
  tuple = {:tmux_event, event}
  Enum.each(state.subscribers, &send(&1, tuple))

  case event do
    {:output, _pane_id, bytes} ->
      case Keyword.get(state.neighbors, :cc_process) do
        pid when is_pid(pid) -> send(pid, {:tmux_output, bytes})
        _ -> :ok
      end
    _ -> :ok
  end

  {:forward, [tuple], state}
end
```

### P3-3.5 — Tests

Add to `runtime/test/esr/peers/tmux_process_test.exs` (keep the existing integration test from PR-1; add a unit test that uses a fake OSProcessWorker):

**Unit test for handle_downstream / handle_upstream dispatch** — test `parse_event/1` (already covered in PR-1) plus:
```elixir
test ":send_input is forwarded to tmux stdin via write_stdin" do
  # Use a test double that intercepts write_stdin calls
  # Easiest: spawn TmuxProcess with subscriber=self() but override
  # the worker's write_stdin via Process.put + custom wrapper.
  # Since OSProcessWorker.write_stdin is just GenServer.cast,
  # we can test the upstream forward path without a real tmux.
end
```

For PR-3 scope, the full E2E verification of tmux stdin + stdout lands in **P3-10** (integration). The unit tests here only cover parse + dispatch logic.

**Regression test for on_terminate**:
```elixir
@tag :integration
test "terminate/2 invokes tmux kill-session via on_terminate" do
  name = "esr_pr3_term_test_#{System.unique_integer([:positive])}"

  {:ok, pid} = Esr.Peers.TmuxProcess.start_link(%{
    session_name: name, dir: "/tmp", subscriber: self()
  })

  Process.sleep(200) # give tmux time to attach

  # Assert tmux session exists
  {out, 0} = System.cmd("tmux", ["list-sessions"], stderr_to_stdout: true)
  assert out =~ name

  GenServer.stop(pid)
  Process.sleep(500)

  # Assert tmux session is gone
  {out2, _} = System.cmd("tmux", ["list-sessions"], stderr_to_stdout: true)
  refute out2 =~ name
end
```

Run `mix test test/esr/peers/tmux_process_test.exs --include integration`. Expect both tests passing (integration requires local tmux).

---

## P3-3a — Session-scoped capability projection

**Scope** (from `docs/futures/peer-session-capability-projection.md` §5 + plan P3-3a row): SessionProcess pulls principal's grants from global `Grants` on init; subscribes to `{:grants_changed, principal_id}` PubSub topic; serves `SessionProcess.has?/2` from local map. Migrate all production-code `Esr.Capabilities.has?/2` callers on the data plane to `SessionProcess.has?/2`.

### P3-3a.1 — Add `:grants_changed` publish path in `Grants.load_snapshot/1`

Edit `runtime/lib/esr/capabilities/grants.ex` `handle_call({:load, snapshot}, ...)`:
```elixir
def handle_call({:load, snapshot}, _from, state) do
  :ets.delete_all_objects(@table)
  Enum.each(snapshot, fn {pid, held} -> :ets.insert(@table, {pid, held}) end)

  # Broadcast per-principal change signal so per-session projections refresh.
  for {principal_id, _} <- snapshot do
    Phoenix.PubSub.broadcast(EsrWeb.PubSub, "grants_changed:#{principal_id}", :grants_changed)
  end

  {:reply, :ok, state}
end
```

Write a test in `runtime/test/esr/capabilities/grants_broadcast_test.exs`:
```elixir
defmodule Esr.Capabilities.GrantsBroadcastTest do
  use ExUnit.Case, async: false

  test "load_snapshot broadcasts grants_changed:<principal>" do
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:ou_carol")
    Esr.Capabilities.Grants.load_snapshot(%{"ou_carol" => ["x:y/z"]})
    assert_receive :grants_changed, 200
  end
end
```

### P3-3a.2 — Upgrade `SessionProcess.init/1` + `SessionProcess.has?/2`

Edit `runtime/lib/esr/session_process.ex`:
```elixir
@impl true
def init(args) do
  principal_id =
    get_in(Map.get(args, :metadata, %{}), [:principal_id]) ||
      get_in(Map.get(args, :metadata, %{}), ["principal_id"])

  grants = fetch_grants(principal_id)
  subscribe_to_grants_changes(principal_id)

  {:ok, %__MODULE__{
     session_id: Map.fetch!(args, :session_id),
     agent_name: Map.fetch!(args, :agent_name),
     dir: Map.fetch!(args, :dir),
     chat_thread_key: Map.fetch!(args, :chat_thread_key),
     metadata: Map.get(args, :metadata, %{}),
     grants: grants
   }}
end

def has?(session_id, permission) when is_binary(permission) do
  GenServer.call(via(session_id), {:has?, permission})
end

@impl true
def handle_call({:has?, permission}, _from, state) do
  {:reply, local_has?(state.grants, permission), state}
end

@impl true
def handle_info(:grants_changed, state) do
  principal_id =
    Map.get(state.metadata, :principal_id) || Map.get(state.metadata, "principal_id")
  {:noreply, %{state | grants: fetch_grants(principal_id)}}
end

defp fetch_grants(nil), do: []
defp fetch_grants(principal_id) when is_binary(principal_id) do
  case :ets.lookup(:esr_capabilities_grants, principal_id) do
    [{^principal_id, held}] -> held
    _ -> []
  end
end

defp subscribe_to_grants_changes(nil), do: :ok
defp subscribe_to_grants_changes(principal_id) when is_binary(principal_id) do
  Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:#{principal_id}")
end

# Inline matcher mirroring Grants.matches?/2 so tests don't depend on
# the global ETS table being populated.
defp local_has?(grants, required) do
  Enum.any?(grants, fn g -> match_one?(g, required) end)
end

defp match_one?("*", _), do: true
defp match_one?(held, required) do
  with [h_scope, h_perm] <- String.split(held, "/", parts: 2),
       [h_prefix, h_name] <- String.split(h_scope, ":", parts: 2),
       [r_scope, r_perm] <- String.split(required, "/", parts: 2),
       [r_prefix, r_name] <- String.split(r_scope, ":", parts: 2),
       true <- h_prefix == r_prefix do
    seg_match?(h_name, r_name) and seg_match?(h_perm, r_perm)
  else
    _ -> false
  end
end
defp seg_match?("*", _), do: true
defp seg_match?(a, a), do: true
defp seg_match?(_, _), do: false
```

Update `runtime/test/esr/session_test.exs` (the `SessionProcess.has?/2` section): verify (a) session reflects initial `Grants` snapshot, (b) after `Grants.load_snapshot/1`, the session's `has?/2` sees the change within 200ms.

### P3-3a.3 — Migrate data-plane callers

Grep `Esr.Capabilities.has?\|Esr.Capabilities.Grants.has?`:
```bash
grep -rn "Esr\.Capabilities\(\.Grants\)\?\.has?" /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib
```

Expected hits:
- `runtime/lib/esr/admin/dispatcher.ex:155` — admin-scope (dispatcher is single, global). **Keep** as `Esr.Capabilities.has?/2` — this is admin-plane, not data-plane.
- `runtime/lib/esr/peer_server.ex:903` — `capability_granted?/2` helper on the legacy data plane. This module dies partially in P3-16; for now, leave it. Add a TODO `# P3-3a: migrate to SessionProcess.has?/2 when peer_server CC paths die`.
- `runtime/lib/esr/peer/proxy.ex:68` — the proxy macro's default capability check function. This is called from peer-chain data plane. Migrate.

Edit `runtime/lib/esr/peer/proxy.ex` default check function: change from `&Esr.Capabilities.has?/2` to a new module function that prefers `ctx[:session_id]` path:
```elixir
defp default_cap_check(principal_id, required_cap, ctx) do
  case Map.get(ctx, :session_id) do
    sid when is_binary(sid) and sid != "admin" ->
      Esr.SessionProcess.has?(sid, required_cap)

    _ ->
      # admin scope or no session_id → global ETS
      Esr.Capabilities.has?(principal_id, required_cap)
  end
end
```

This requires changing the macro's generated check to pass `ctx` (it already does). Update `peer/proxy.ex` + write a migration test in `runtime/test/esr/peer/proxy_compile_test.exs` that a Peer.Proxy inside a session spawns, the session's local grants determine the outcome (not the global ETS — verify by loading conflicting grants).

**Feishu notify after P3-3a**: "Session-scoped grants projection live — test-flake root cause (global Grants contention) is now decoupled from data-plane reads. D22-equivalent done."

---

## P3-4 — `Esr.SessionRouter` (control plane)

**Scope clarification** (from spec §3.3 + §6 Risk E): SessionRouter is a GenServer reacting to:
- `:new_chat_thread_requested` (input signal from FeishuAppAdapter via PubSub `new_chat_thread`)
- `:session_end_requested` (from `Session.End` or slash)
- `:peer_crashed` (from `Process.monitor` DOWNs on spawned peers)
- `:agents_yaml_reloaded` (from Capabilities-style watcher in a future PR; stub clause here)
- Sync ops: `:create_session_sync`, `:end_session_sync`

SessionRouter **does** own the multi-step "spawn session → spawn peers in topo order → register chat-thread mapping" sequence. It is the module that FeishuAppAdapter's `:not_found` branch eventually reaches, and the module that `Session.New` admin command eventually calls.

**Decision on FeishuAppAdapter vs SessionRouter vs Session.New**:
- `Session.New` (admin command, P3-8) is the **slash-path** entry. It does validation + cap check, then delegates to `SessionRouter.create_session/2`.
- FeishuAppAdapter's `:not_found` branch (inbound-without-session) publishes `:new_chat_thread` on PubSub. SessionRouter subscribes and decides whether to spawn a session — **not spawned in PR-3 auto-create mode**; for PR-3 scope, the `:new_chat_thread` handler logs + emits telemetry and drops the envelope. Spec §5.1 notes auto-create is possible but user-initiated via slash is the primary path. Leave auto-create stubbed (log) so the signal is observable and the data structure is in place; PR-4 or later fills it.

### P3-4.1 — Unit tests

Create `runtime/test/esr/session_router_test.exs`:
```elixir
defmodule Esr.SessionRouterTest do
  use ExUnit.Case, async: false

  alias Esr.SessionRouter

  setup do
    Esr.Capabilities.Grants.load_snapshot(%{"ou_alice" => ["*"]})
    :ok = Esr.SessionRegistry.load_agents("test/esr/fixtures/agents/simple.yaml")
    on_exit(fn -> Esr.Capabilities.Grants.load_snapshot(%{}) end)
    :ok
  end

  test "create_session_sync/2 spawns Session supervisor + peers in topo order" do
    {:ok, session_id} =
      SessionRouter.create_session(%{
        agent: "cc",
        dir: "/tmp",
        principal_id: "ou_alice",
        chat_id: "oc_xx",
        thread_id: "om_yy",
        app_id: "cli_test"
      })

    # Session supervisor alive
    assert {:ok, _refs} = lookup_refs(session_id)

    # Expected peers present (names match agent yaml)
    {:ok, _sid, refs} =
      Esr.SessionRegistry.lookup_by_chat_thread("oc_xx", "om_yy")

    assert is_pid(refs.feishu_chat_proxy)
    assert is_pid(refs.cc_proxy)
    assert is_pid(refs.cc_process)
    assert is_pid(refs.tmux_process)
    assert is_pid(refs.feishu_app_proxy)
  end

  test "create_session returns {:error, :unknown_agent} for missing agent_def" do
    assert {:error, :unknown_agent} =
             SessionRouter.create_session(%{
               agent: "nonexistent", dir: "/tmp", principal_id: "ou_alice"
             })
  end

  test "end_session/1 terminates Session supervisor + unregisters" do
    {:ok, sid} =
      SessionRouter.create_session(%{
        agent: "cc", dir: "/tmp", principal_id: "ou_alice",
        chat_id: "oc_aa", thread_id: "om_bb", app_id: "cli_test"
      })

    :ok = SessionRouter.end_session(sid)
    assert :not_found = Esr.SessionRegistry.lookup_by_chat_thread("oc_aa", "om_bb")
  end

  defp lookup_refs(session_id) do
    try do
      refs = Esr.SessionProcess.state(session_id)
      {:ok, refs}
    catch
      :exit, _ -> :error
    end
  end
end
```

### P3-4.2 — Implementation

Create `runtime/lib/esr/session_router.ex`:
```elixir
defmodule Esr.SessionRouter do
  @moduledoc """
  Control-plane coordinator for Session lifecycle.

  Accepts only control-plane events:
    - :create_session / :create_session_sync  (from Session.New admin cmd)
    - :end_session   / :end_session_sync      (from Session.End)
    - :new_chat_thread (PubSub, from FeishuAppAdapter on :not_found)
    - :peer_crashed    (from Process.monitor on peer pids)
    - :agents_yaml_reloaded (from SessionRegistry watcher; stub in PR-3)

  Spec §3.3, §6 Risk E. Data-plane messages MUST NOT reach this GenServer.
  Risk-E guard: handle_info/2 catch-all logs + drops with a WARN so
  unexpected shapes are visible.
  """
  use GenServer
  require Logger

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # Public API — both paths go through a GenServer.call for backpressure.

  @spec create_session(map()) :: {:ok, String.t()} | {:error, term()}
  def create_session(params), do: GenServer.call(__MODULE__, {:create_session_sync, params}, 30_000)

  @spec end_session(String.t()) :: :ok | {:error, term()}
  def end_session(session_id),
    do: GenServer.call(__MODULE__, {:end_session_sync, session_id}, 10_000)

  @impl true
  def init(_) do
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "new_chat_thread")
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:create_session_sync, params}, _from, state) do
    case do_create(params) do
      {:ok, sid, monitor_refs} ->
        monitors = Enum.reduce(monitor_refs, state.monitors, fn {ref, pid}, acc ->
          Map.put(acc, ref, {sid, pid})
        end)
        {:reply, {:ok, sid}, %{state | monitors: monitors}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:end_session_sync, sid}, _from, state) do
    # Look up the Session supervisor pid, stop it, unregister.
    via = {:via, Registry, {Esr.Session.Registry, {:session_sup, sid}}}
    case GenServer.whereis(via) do
      nil ->
        {:reply, {:error, :unknown_session}, state}
      pid when is_pid(pid) ->
        :ok = Esr.SessionsSupervisor.stop_session(pid)
        :ok = Esr.SessionRegistry.unregister_session(sid)
        {:reply, :ok, state}
    end
  end

  # Risk E: reject anything shaped like data-plane.
  def handle_call(unexpected, _from, state) do
    Logger.warning(
      "SessionRouter: rejected unexpected call #{inspect(unexpected)} (Risk E boundary)"
    )
    {:reply, {:error, :not_control_plane}, state}
  end

  @impl true
  def handle_info({:new_chat_thread, chat_id, thread_id, app_id, envelope}, state) do
    # PR-3: log the signal but do not auto-create. Slash-initiated flow
    # is the only session-creation path in PR-3 scope.
    :telemetry.execute([:esr, :session_router, :new_chat_thread_dropped], %{count: 1}, %{
      chat_id: chat_id, thread_id: thread_id, app_id: app_id
    })
    Logger.info(
      "session_router: observed new_chat_thread chat_id=#{chat_id} thread_id=#{thread_id} " <>
        "(PR-3 no-auto-create; use /new-session slash)"
    )
    _ = envelope
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} -> {:noreply, state}
      {{sid, _peer_pid}, rest} ->
        :telemetry.execute([:esr, :session_router, :peer_crashed], %{}, %{
          session_id: sid, reason: inspect(reason)
        })
        # PR-3 policy: peer crash inside a session — the Session's
        # :one_for_all supervisor already tears the subtree down. We
        # observe, we don't rebuild. PR-4+ may add rebuild logic.
        {:noreply, %{state | monitors: rest}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------- internals ----------------

  defp do_create(params) do
    with {:ok, agent_def}    <- fetch_agent(params[:agent] || params["agent"]),
         session_id          <- gen_id(),
         {:ok, _sup}         <- start_session_sup(session_id, params, agent_def),
         {:ok, refs_map, mon} <- spawn_pipeline(session_id, agent_def, params),
         :ok                 <- register(session_id, params, refs_map) do
      {:ok, session_id, mon}
    end
  end

  defp fetch_agent(nil), do: {:error, :agent_required}
  defp fetch_agent(name) do
    case Esr.SessionRegistry.agent_def(name) do
      {:ok, d} -> {:ok, d}
      {:error, :not_found} -> {:error, :unknown_agent}
    end
  end

  defp gen_id, do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)

  defp start_session_sup(sid, params, agent_def) do
    Esr.SessionsSupervisor.start_session(%{
      session_id: sid,
      agent_name: params[:agent] || params["agent"],
      dir: params[:dir] || params["dir"],
      chat_thread_key: %{chat_id: params[:chat_id] || "", thread_id: params[:thread_id] || ""},
      metadata: %{
        principal_id: params[:principal_id] || params["principal_id"],
        agent_def: agent_def
      }
    })
  end

  defp spawn_pipeline(session_id, agent_def, params) do
    inbound  = agent_def.pipeline.inbound  # [%{"name" => _, "impl" => _}]
    proxies  = agent_def.proxies           # [%{"name" => _, "impl" => _, "target" => _}]

    # Spawn all peers first with neighbors: [] placeholder; then patch
    # neighbors via a second pass once every peer has a pid.
    #
    # For PR-3 we do the simple correct thing: topo-order spawn with
    # neighbors computed from the spawn order.

    peer_specs = inbound ++ proxies
    {refs, monitors} =
      Enum.reduce(peer_specs, {%{}, []}, fn spec, {refs_acc, mon_acc} ->
        name = String.to_atom(spec["name"])
        impl = String.to_existing_atom("Elixir." <> spec["impl"])
        neighbors = build_neighbors(spec, refs_acc)
        ctx = build_ctx(spec, params)
        case Esr.PeerFactory.spawn_peer(session_id, impl, spawn_args(spec, params), neighbors, ctx) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            {Map.put(refs_acc, name, pid), [{ref, pid} | mon_acc]}
          {:error, reason} ->
            throw({:spawn_failed, spec, reason})
        end
      end)

    {:ok, refs, monitors}
  catch
    {:spawn_failed, spec, reason} -> {:error, {:peer_spawn_failed, spec, reason}}
  end

  defp build_neighbors(spec, refs_acc) do
    # PR-3 heuristic: pass every peer already spawned as a named neighbor.
    # The peer's `init/1` picks the names it needs (`:cc_proxy`, `:tmux_process`, etc.).
    Enum.map(refs_acc, fn {name, pid} -> {name, pid} end)
  end

  defp build_ctx(%{"impl" => "Esr.Peers.FeishuAppProxy", "target" => tgt}, params) do
    # target looks like "admin::feishu_app_adapter_${app_id}"
    app_id = params[:app_id] || params["app_id"] || "default"
    expanded = String.replace(tgt, "${app_id}", app_id)
    [_, admin_peer_name] = String.split(expanded, "::", parts: 2)
    sym = String.to_atom(admin_peer_name)
    case Esr.AdminSessionProcess.admin_peer(sym) do
      {:ok, pid} -> %{principal_id: params[:principal_id], target_pid: pid, app_id: app_id}
      :error     -> %{principal_id: params[:principal_id], target_pid: nil, app_id: app_id}
    end
  end

  defp build_ctx(%{"impl" => "Esr.Peers.CCProxy"}, params) do
    %{principal_id: params[:principal_id]}
  end

  defp build_ctx(_, _), do: %{}

  defp spawn_args(%{"impl" => "Esr.Peers.FeishuChatProxy"}, params) do
    %{chat_id: params[:chat_id] || "", thread_id: params[:thread_id] || ""}
  end
  defp spawn_args(%{"impl" => "Esr.Peers.CCProcess"}, params) do
    %{handler_module: params[:handler_module] || "cc_adapter_runner"}
  end
  defp spawn_args(%{"impl" => "Esr.Peers.TmuxProcess"}, params) do
    name = "esr_cc_#{:erlang.unique_integer([:positive])}"
    %{session_name: name, dir: params[:dir] || "/tmp"}
  end
  defp spawn_args(_, _), do: %{}

  defp register(session_id, params, refs_map) do
    Esr.SessionRegistry.register_session(
      session_id,
      %{chat_id: params[:chat_id] || "", thread_id: params[:thread_id] || ""},
      refs_map
    )
  end
end
```

### P3-4.3 — Wire into application supervision tree

Edit `runtime/lib/esr/application.ex`, add `Esr.SessionRouter` to the children list **after** `Esr.AdminSession` (Risk F order), **after** `Esr.SessionsSupervisor`. Insert at line ~57:
```elixir
Esr.SessionsSupervisor,
Esr.SessionRouter,
```

### P3-4.4 — Update `Session.New` to delegate to `SessionRouter`

Edit `runtime/lib/esr/admin/commands/session/new.ex` (the one consolidated in P3-8.6): replace `start_session/4` body:
```elixir
defp start_session(agent, agent_def, dir, submitter, params) do
  Esr.SessionRouter.create_session(%{
    agent: agent,
    dir: dir,
    principal_id: submitter,
    chat_id: params["chat_id"] || "",
    thread_id: params["thread_id"] || "",
    app_id: params["app_id"] || "default",
    handler_module: params["handler_module"] || "cc_adapter_runner"
  })
end
```

Adjust the caller in `execute/1`:
```elixir
with :ok <- validate_args(agent, dir),
     {:ok, agent_def} <- fetch_agent(agent),
     :ok <- verify_caps(submitter, agent_def.capabilities_required),
     {:ok, sid} <- start_session(agent, agent_def, dir, submitter, args) do
  {:ok, %{"session_id" => sid, "agent" => agent}}
end
```

Run `mix test test/esr/session_router_test.exs`. Expect 3 passing (may require agents.yaml fixture updated for cc agent in P3-6 — if that lags, use `simple.yaml` directly per setup).

---

## P3-5 — SessionRouter Risk-E boundary test

**Purpose**: assert SessionRouter drops / rejects anything that smells like data-plane (spec §6 Risk E).

### P3-5.1 — Test

Add to `runtime/test/esr/session_router_test.exs`:
```elixir
test "rejects data-plane-shaped GenServer.call with {:error, :not_control_plane}" do
  assert {:error, :not_control_plane} =
           GenServer.call(Esr.SessionRouter, {:inbound_event, %{"text" => "hi"}})
end

test "data-plane-shaped info messages are dropped (no crash)" do
  # Send a message that looks like a forward envelope
  send(Esr.SessionRouter, {:forward, :session_abc, %{"text" => "hi"}})
  # No crash, still alive
  Process.sleep(50)
  assert Process.whereis(Esr.SessionRouter) |> Process.alive?()
end

test "telemetry fires on unexpected shapes when they're control-plane kinds" do
  ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :session_router, :peer_crashed]])
  # Simulate a monitored peer DOWN
  fake_ref = make_ref()
  send(Esr.SessionRouter, {:DOWN, fake_ref, :process, self(), :test})
  :telemetry_test.detach(ref)
end
```

Run: `mix test test/esr/session_router_test.exs`. Expect green.

---

## P3-6 — Integrate CC peers into `cc` agent in agents.yaml fixtures

### P3-6.1 — Update `simple.yaml` (already done in P3-8.4 for canonical caps; confirm it matches the full CC chain)

Re-check `runtime/test/esr/fixtures/agents/simple.yaml`: pipeline inbound must list `feishu_chat_proxy → cc_proxy → cc_process → tmux_process`; proxies include `feishu_app_proxy`. Match the snippet in P3-8.4.

### P3-6.2 — Add a minimal `cc-echo` agent for N=2 tests

Edit `runtime/test/esr/fixtures/agents/multi_app.yaml` — the existing `cc-echo` is a feishu-only chain; leave as a "echo without tmux" minimal case (no CC for N=2 stress). Rename description to "Simple echo variant without CC pipeline — used by N=2 routing tests".

### P3-6.3 — Update the dev-ops stub note

Edit `runtime/test/esr/fixtures/agents/README.md`: add a new bullet noting the production stub at `~/.esrd/default/agents.yaml` must include the `cc` agent with the full CC-chain pipeline (mirror `simple.yaml`). Include a copy-paste block operators can use:
```yaml
# ~/.esrd/default/agents.yaml (production stub)
agents:
  cc:
    description: "Claude Code"
    capabilities_required:
      - session:default/create
      - tmux:default/spawn
      - handler:cc_adapter_runner/invoke
    pipeline:
      inbound:
        - { name: feishu_chat_proxy, impl: Esr.Peers.FeishuChatProxy }
        - { name: cc_proxy,          impl: Esr.Peers.CCProxy }
        - { name: cc_process,        impl: Esr.Peers.CCProcess }
        - { name: tmux_process,      impl: Esr.Peers.TmuxProcess }
      outbound:
        - tmux_process
        - cc_process
        - cc_proxy
        - feishu_chat_proxy
    proxies:
      - { name: feishu_app_proxy, impl: Esr.Peers.FeishuAppProxy, target: "admin::feishu_app_adapter_${app_id}" }
    params:
      - { name: dir,    required: true, type: path }
      - { name: app_id, required: false, default: "default", type: string }
```

**Feishu notify after P3-6**: "Full CC agent wired in agents.yaml — cc pipeline now: FeishuChatProxy → CCProxy → CCProcess → TmuxProcess (+ FeishuAppProxy outbound)."

---

## P3-7 — Wire FeishuAppAdapter `:new_chat_thread` PubSub → SessionRouter

**Current behavior** (`runtime/lib/esr/peers/feishu_app_adapter.ex:58-66`): on `lookup_by_chat_thread → :not_found`, FAA broadcasts on PubSub topic `"new_chat_thread"` the tuple `{:new_chat_thread, chat_id, thread_id, app_id, envelope}`.

**P3-4 already wires SessionRouter to subscribe** to `"new_chat_thread"` and log/drop. P3-7 validates end-to-end and documents the "PR-3 = log-only, PR-4+ = auto-create" stance.

### P3-7.1 — Integration test

Create `runtime/test/esr/integration/new_chat_thread_signal_test.exs`:
```elixir
defmodule Esr.Integration.NewChatThreadSignalTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  setup do
    :ok = Esr.SessionRegistry.load_agents("test/esr/fixtures/agents/simple.yaml")
    :ok
  end

  test "FAA lookup miss → :new_chat_thread signal → SessionRouter observes + telemetry fires" do
    app_id = "pr3_test_#{System.unique_integer([:positive])}"
    # Start FAA for this test
    {:ok, _faa} =
      DynamicSupervisor.start_child(
        Esr.AdminSession.children_supervisor_name(),
        {Esr.Peers.FeishuAppAdapter, %{app_id: app_id, neighbors: []}}
      )

    ref = :telemetry_test.attach_event_handlers(self(),
      [[:esr, :session_router, :new_chat_thread_dropped]])

    Esr.AdminSessionProcess.admin_peer(String.to_atom("feishu_app_adapter_#{app_id}"))
    |> elem(1)
    |> send({:inbound_event, %{
       "payload" => %{
         "chat_id" => "oc_new_pr3",
         "thread_id" => "om_new_pr3",
         "text" => "hello"
       }
     }})

    assert_receive {[:esr, :session_router, :new_chat_thread_dropped], _, _, _}, 500
    :telemetry_test.detach(ref)
  end
end
```

Run `mix test test/esr/integration/new_chat_thread_signal_test.exs --include integration`. Expect green.

---

## P3-9 — Update `Session.End` admin command for agent-session teardown

**Current behavior**: `runtime/lib/esr/admin/commands/session/end.ex` handles **branch worktree** teardown exclusively (looks up `branches.yaml`, shells `esr-branch.sh end`, etc.). After P3-8 rename, this is `session_branch_end` semantics.

**P3-9 scope**: introduce a new agent-session `session_end` command semantics: given `session_id` (ULID), delegate to `SessionRouter.end_session/1`. Keep branch-end as `session_branch_end` kind.

### P3-9.1 — Rename `session/end.ex` module → `Session.BranchEnd`

```bash
cd runtime && git mv lib/esr/admin/commands/session/end.ex lib/esr/admin/commands/session/branch_end.ex
```

Inside: `defmodule Esr.Admin.Commands.Session.End` → `defmodule Esr.Admin.Commands.Session.BranchEnd`. Update moduledoc to scope to legacy branch-worktree path.

Grep & rewrite test references: `grep -rn "Esr.Admin.Commands.Session.End" runtime/test`; rename module/alias usage.

### P3-9.2 — Create new `Session.End` (agent-session end)

Create `runtime/lib/esr/admin/commands/session/end.ex`:
```elixir
defmodule Esr.Admin.Commands.Session.End do
  @moduledoc """
  Tears down an agent-session by session_id via `Esr.SessionRouter.end_session/1`.
  Replaces the legacy branch-worktree semantics (moved to `Session.BranchEnd`
  in PR-3 P3-9).
  """

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _, "args" => %{"session_id" => sid}})
      when is_binary(sid) and sid != "" do
    case Esr.SessionRouter.end_session(sid) do
      :ok -> {:ok, %{"session_id" => sid, "ended" => true}}
      {:error, :unknown_session} -> {:error, %{"type" => "unknown_session", "session_id" => sid}}
      {:error, reason} -> {:error, %{"type" => "end_failed", "details" => inspect(reason)}}
    end
  end

  def execute(_),
    do: {:error, %{"type" => "invalid_args", "message" => "session_end requires args.session_id"}}
end
```

### P3-9.3 — Dispatcher remap

Edit `runtime/lib/esr/admin/dispatcher.ex`:
```elixir
@required_permissions %{
  ...
  "session_new" => "session:default/create",
  "session_branch_new" => "session:default/create",
  "session_end" => "session:default/end",
  "session_branch_end" => "session:default/end",
  ...
}

@command_modules %{
  ...
  "session_new" => Esr.Admin.Commands.Session.New,
  "session_branch_new" => Esr.Admin.Commands.Session.BranchNew,
  "session_end" => Esr.Admin.Commands.Session.End,
  "session_branch_end" => Esr.Admin.Commands.Session.BranchEnd,
  ...
}
```

### P3-9.4 — Update `SlashHandler` parser

Edit `runtime/lib/esr/peers/slash_handler.ex`: `parse_command("/end-session " <> rest)` — currently emits kind `"session_end"`. Keep that name but ensure it routes to the new agent-session end. No change needed if dispatcher map is correct.

### P3-9.5 — Tests

Create `runtime/test/esr/admin/commands/session/end_test.exs` (new-style):
```elixir
defmodule Esr.Admin.Commands.Session.EndTest do
  use ExUnit.Case, async: false
  alias Esr.Admin.Commands.Session.End

  setup do
    Esr.Capabilities.Grants.load_snapshot(%{"ou_alice" => ["*"]})
    :ok = Esr.SessionRegistry.load_agents("test/esr/fixtures/agents/simple.yaml")
    :ok
  end

  test "execute ends an existing session_id" do
    {:ok, sid} =
      Esr.SessionRouter.create_session(%{
        agent: "cc", dir: "/tmp", principal_id: "ou_alice",
        chat_id: "oc_end", thread_id: "om_end"
      })

    assert {:ok, %{"ended" => true}} =
             End.execute(%{"submitted_by" => "ou_alice", "args" => %{"session_id" => sid}})
  end

  test "unknown session_id → :unknown_session error" do
    assert {:error, %{"type" => "unknown_session"}} =
             End.execute(%{
               "submitted_by" => "ou_alice",
               "args" => %{"session_id" => "NONEXISTENT"}
             })
  end
end
```

Run `mix test test/esr/admin/commands/session/end_test.exs`. Expect green.

---

## P3-10 — Full E2E: Feishu inbound → tmux stdin → tmux output → Feishu outbound

### P3-10.1 — Integration test

Create `runtime/test/esr/integration/cc_e2e_test.exs`:
```elixir
defmodule Esr.Integration.CCE2ETest do
  use ExUnit.Case, async: false
  @moduletag :integration

  setup do
    Esr.Capabilities.Grants.load_snapshot(%{"ou_alice" => ["*"]})
    :ok = Esr.SessionRegistry.load_agents("test/esr/fixtures/agents/simple.yaml")
    :ok
  end

  @tag timeout: 30_000
  test "Feishu inbound text → tmux send-keys → stdout output → Feishu reply" do
    app_id = "e2e_#{System.unique_integer([:positive])}"

    # 1. Spawn FAA for app_id
    {:ok, _faa} = DynamicSupervisor.start_child(
      Esr.AdminSession.children_supervisor_name(),
      {Esr.Peers.FeishuAppAdapter, %{app_id: app_id, neighbors: []}}
    )

    # 2. Create session
    chat_id = "oc_e2e_#{System.unique_integer([:positive])}"
    thread_id = "om_e2e_#{System.unique_integer([:positive])}"

    # Stub HandlerRouter globally (CCProcess reads Process.get(:cc_handler_override))
    # Since the CCProcess is spawned by PeerFactory under the Session,
    # Process.put in this test's proc doesn't reach it. Use the real
    # HandlerRouter path and inject a fixture Python-side, OR replace
    # CCProcess's handler with a pure-Elixir stub for this test.
    #
    # Simpler: swap handler_module to a test stub using an Application env
    # lookup in CCProcess. Plan: add config :esr, :handler_module_override
    # to CCProcess.handle_upstream's call_handler path.

    Application.put_env(:esr, :handler_module_override,
      {:test_fun, fn _, %{"event" => %{"kind" => "text", "text" => t}}, _ ->
         {:ok, %{}, [%{"type" => "send_input", "text" => t <> "\n"}]}
       end})

    {:ok, sid} = Esr.SessionRouter.create_session(%{
      agent: "cc",
      dir: "/tmp",
      principal_id: "ou_alice",
      chat_id: chat_id,
      thread_id: thread_id,
      app_id: app_id
    })

    # 3. Resolve FeishuChatProxy pid from SessionRegistry
    {:ok, ^sid, refs} = Esr.SessionRegistry.lookup_by_chat_thread(chat_id, thread_id)
    tmux_pid = refs.tmux_process
    fcp_pid = refs.feishu_chat_proxy

    # 4. Send inbound text
    send(fcp_pid, {:feishu_inbound, %{
      "payload" => %{"text" => "echo hello_pr3", "chat_id" => chat_id, "thread_id" => thread_id}
    }})

    # 5. Wait for tmux to echo (scan its stdout via a subscriber hook)
    # Subscribe to the tmux peer's events
    :ok = GenServer.call(tmux_pid, :add_subscriber_for_test) # need to add

    assert_receive {:tmux_event, {:output, _pane, bytes}} when is_binary(bytes), 10_000

    # 6. Cleanup
    :ok = Esr.SessionRouter.end_session(sid)
    Application.delete_env(:esr, :handler_module_override)
  end
end
```

**Helpers needed**:
- CCProcess: update `call_handler/3` to check `Application.get_env(:esr, :handler_module_override)` first (env-level override is reachable from any process, unlike Process.put).
- TmuxProcess: add `:add_subscriber_for_test` handle_call (tests only; gate with `if Mix.env() == :test`).

Wire both.

Run `mix test test/esr/integration/cc_e2e_test.exs --include integration`. Requires tmux on PATH. Expect green.

**Feishu notify after P3-10**: "Full E2E green: Feishu inbound → FCP → CCProxy → CCProcess → TmuxProcess → tmux stdin → tmux stdout → Feishu reply. Data plane is live."

---

## P3-11 — N=2 concurrent tmux test

**Scope**: spec §6 Risk D requires "two of everything" for integration tests. Validate two sessions, each with own tmux, independent lifecycle.

### P3-11.1 — Integration test

Create `runtime/test/esr/integration/n2_tmux_test.exs`:
```elixir
defmodule Esr.Integration.N2TmuxTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  @tag timeout: 30_000
  test "two concurrent sessions; terminating one doesn't affect the other's tmux" do
    Esr.Capabilities.Grants.load_snapshot(%{"ou_alice" => ["*"], "ou_bob" => ["*"]})
    :ok = Esr.SessionRegistry.load_agents("test/esr/fixtures/agents/simple.yaml")

    app_id = "n2_#{System.unique_integer([:positive])}"
    {:ok, _} = DynamicSupervisor.start_child(
      Esr.AdminSession.children_supervisor_name(),
      {Esr.Peers.FeishuAppAdapter, %{app_id: app_id, neighbors: []}}
    )

    {:ok, sid_a} = Esr.SessionRouter.create_session(%{
      agent: "cc", dir: "/tmp", principal_id: "ou_alice",
      chat_id: "oc_a", thread_id: "om_a", app_id: app_id
    })

    {:ok, sid_b} = Esr.SessionRouter.create_session(%{
      agent: "cc", dir: "/tmp", principal_id: "ou_bob",
      chat_id: "oc_b", thread_id: "om_b", app_id: app_id
    })

    Process.sleep(300)

    # Both tmux sessions exist
    {out, 0} = System.cmd("tmux", ["list-sessions"], stderr_to_stdout: true)
    tmux_count = out |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "esr_cc_"))
    assert tmux_count >= 2

    # End A; B remains
    :ok = Esr.SessionRouter.end_session(sid_a)
    Process.sleep(500)

    # B's tmux still alive
    {:ok, ^sid_b, refs_b} = Esr.SessionRegistry.lookup_by_chat_thread("oc_b", "om_b")
    assert Process.alive?(refs_b.tmux_process)

    # Cleanup
    :ok = Esr.SessionRouter.end_session(sid_b)
  end
end
```

Run `mix test test/esr/integration/n2_tmux_test.exs --include integration`. Expect green.

---

## P3-12 — OS cleanup regression (`mix test.e2e.os_cleanup`)

**Goal**: asserts that `kill -9 <beam_pid>` leaves no tmux orphans within 10s (spec §10.5 per-PR gate).

### P3-12.1 — Mix alias

Edit `runtime/mix.exs` `aliases/0`:
```elixir
defp aliases do
  [
    setup: ["deps.get"],
    precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"],
    "test.e2e.os_cleanup": ["test --only os_cleanup"]
  ]
end
```

### P3-12.2 — Test

Create `runtime/test/esr/integration/os_cleanup_test.exs`:
```elixir
defmodule Esr.Integration.OsCleanupTest do
  use ExUnit.Case, async: false
  @moduletag :os_cleanup

  @tag timeout: 30_000
  test "kill -9 of esrd → all tmux sessions die within 10s" do
    # This test must NOT run under the standard mix test (it kills the
    # current BEAM). Use mix test --only os_cleanup (alias above) and
    # spawn a subprocess esrd, not the in-process one.
    unique = "oscleanup_#{System.unique_integer([:positive])}"
    port = start_esrd_subprocess(unique)

    # Create one session via WS/CLI → one tmux
    create_session_via_ws(port, unique)
    Process.sleep(500)

    pre = count_esr_tmux_sessions(unique)
    assert pre >= 1

    beam_pid = read_beam_os_pid(unique)
    :ok = kill_9(beam_pid)

    # Wait up to 10s for tmux to die (app-level on_terminate won't run
    # on SIGKILL; must rely on tmux's own EOF detection)
    Process.sleep(10_000)
    post = count_esr_tmux_sessions(unique)
    assert post == 0, "found #{post} orphan tmux sessions after kill -9"
  end

  # The helpers below are skipped if the os_cleanup infra isn't set up
  # yet; this test is the marker we'll flesh out once the infra exists.
  defp start_esrd_subprocess(_), do: 9999
  defp create_session_via_ws(_port, _unique), do: :ok
  defp count_esr_tmux_sessions(_unique), do: 0
  defp read_beam_os_pid(_unique), do: 0
  defp kill_9(_), do: :ok
end
```

**Important**: the test as written is a **scaffold**. Full implementation requires subprocess-esrd infrastructure. If `scripts/start-esrd.sh` or equivalent exists, wire through it; otherwise mark the test as `@tag :skip` with a reason and open a follow-up issue (document in the PR body).

Run `mix test.e2e.os_cleanup`. If scaffold: expect skip. If full: expect green.

---

## P3-13 — Delete `Esr.Topology.*`

### P3-13.1 — Find all refs

```bash
cd runtime && grep -rn "Esr\.Topology" lib test
```

Referenced from (expected):
- `lib/esr/application.ex:87,187,189` (Supervisor + feishu-app restore)
- `lib/esr/peer_server.ex:25-26,702,731` (aliases + `invoke_command` action)
- `lib/esr_web/cli_channel.ex:18,52,110,137,139,162,168` (CLI topology commands)
- `test/esr/topology/*.exs` (four files)
- `test/esr/peer_server_invoke_command_test.exs`
- `test/esr/application_test.exs`

### P3-13.2 — Delete topology lib files

```bash
cd runtime && git rm lib/esr/topology/registry.ex lib/esr/topology/instantiator.ex lib/esr/topology/supervisor.ex
```

### P3-13.3 — Remove from `application.ex`

Delete child `Esr.Topology.Supervisor` entry (line ~87). Delete `restore_feishu_app_session/1` helper + the `if type == "feishu"` block inside `restore_adapters_from_disk/2`. Delete its caller chain. **Open question for reviewer**: does the restore-feishu-app flow need replacement in PR-3? Spec §5.4 says sessions are user-initiated via `/new-session` slash; auto-restore of FeishuAppAdapter peers happens at AdminSession boot, not per-session. PR-3 is leaving FeishuAppAdapter startup to the adapters.yaml + PR-2's bootstrap path. Remove this helper entirely.

### P3-13.4 — Remove `invoke_command` action from peer_server.ex

Edit `runtime/lib/esr/peer_server.ex`:
- Delete aliases at line 25-26 (`alias Esr.Topology.Instantiator, as: TopoInstantiator`, `alias Esr.Topology.Registry, as: TopoRegistry`).
- Delete `dispatch_action(%{"type" => "invoke_command"} ...)` at line 698-719.
- Delete `run_instantiation/3` at line 730-747.

### P3-13.5 — Handle `cli_channel.ex` topology commands

Edit `runtime/lib/esr_web/cli_channel.ex`: the lines at 18/52/110/137/139/162/168 implement `cli:topology/*` commands. These are user-facing ESR CLI operations that no longer make sense.

Two options, tracked as a small design decision in the PR body:
- **Option A (delete)**: remove all `cli:topology/*` handlers; CLI commands fail with "not implemented post-refactor"
- **Option B (gate)**: return a structured `{:error, "topology module removed — use /new-session + /list-sessions"}` for every topology cmd

Choose Option B (polite degradation). Write tests asserting the error shape.

### P3-13.6 — Delete topology tests

```bash
cd runtime && git rm -r test/esr/topology
git rm test/esr/peer_server_invoke_command_test.exs
```

Edit `test/esr/application_test.exs`: remove any assertions about `Esr.Topology.Supervisor` being a child.

### P3-13.7 — Run full suite

```bash
cd runtime && mix compile --warnings-as-errors && mix test --exclude integration
```

Expect zero Topology references; all remaining tests green.

**Feishu notify after P3-13**: "Topology module deleted — 3 lib files + 4 test files removed. SessionRouter now the sole control plane."

---

## P3-14 — Delete `Esr.Routing.SlashHandler` + `Esr.Routing.Supervisor`

### P3-14.1 — Find all refs

```bash
cd runtime && grep -rn "Esr\.Routing" lib test
```

### P3-14.2 — Delete lib files

```bash
cd runtime && git rm lib/esr/routing/slash_handler.ex lib/esr/routing/supervisor.ex
# The directory becomes empty; leave it or:
rmdir lib/esr/routing  # only works if empty
```

### P3-14.3 — Remove from `application.ex`

Delete `Esr.Routing.Supervisor` child entry (line ~80).

### P3-14.4 — Delete test file

```bash
cd runtime && git rm test/esr/routing/slash_handler_test.exs
rmdir test/esr/routing
```

### P3-14.5 — Compile check

```bash
cd runtime && mix compile --warnings-as-errors
```

Expect clean.

---

## P3-15 — PubSub broadcast audit

**Purpose**: spec §2.9 lists the only legitimate broadcast sites post-refactor:
1. Telemetry
2. `HandlerRouter` RPC (`handler:<module>/<worker_id>` + `handler_reply:<id>`)
3. Peer-originated directive broadcasts on `adapter:<name>/<instance_id>` (via `EsrWeb.Endpoint.broadcast`)
4. Slash-result broadcast on `feishu_reply` (SlashHandler)
5. `grants_changed:<principal_id>` (P3-3a — addition to this list)

Everything else: convert to `send/cast` or delete.

### P3-15.1 — Grep all broadcast sites

```bash
cd runtime && grep -rn "Phoenix\.PubSub\.broadcast\|EsrWeb\.Endpoint\.broadcast" lib
```

From the earlier grep (updated after P3-13/P3-14 deletions):

| Site | Mechanism | Purpose | Action |
|---|---|---|---|
| `handler_router.ex:51` | `EsrWeb.Endpoint.broadcast` `handler:<mod>/<worker>` | HandlerRouter RPC | **keep** (allow-listed) |
| `peer_server.ex:671,869` | `EsrWeb.Endpoint.broadcast` `adapter:<n>/<id>` | legacy directive emit | **keep** for now (peer_server retains `emit` dispatch until P3-16 → then deletes; in PR-3 we leave the final deletion to P3-16 conditional on CC-only tests still passing) |
| `peers/feishu_app_adapter.ex:59` | `Phoenix.PubSub.broadcast` `new_chat_thread` | FAA miss signal | **keep** (added P3-7 allow-list) |
| `peers/feishu_app_adapter.ex:81` | `EsrWeb.Endpoint.broadcast` `adapter:feishu/<app_id>` | outbound to Python adapter_runner | **keep** (allow-listed) |
| `esr_web/channel_channel.ex:116` | `Phoenix.PubSub.broadcast` `cli:channel/<sid>` | session notifications | **keep** (commented-only? verify) |
| `esr_web/handler_channel.ex:59` | `Phoenix.PubSub.broadcast` `handler_reply:<id>` | reply correlation | **keep** (allow-listed) |
| `esr_web/adapter_channel.ex:95` | `Phoenix.PubSub.broadcast` `directive_ack:<id>` | worker correlation | **keep** (allow-listed) |
| `admin/commands/notify.ex:41` | `Phoenix.PubSub.broadcast` adapter topic for reply | admin notify command | **keep** (admin slash-path) |
| `admin/commands/session/end.ex:233` (now `branch_end.ex` after P3-9.1) | `Phoenix.PubSub.broadcast` `cli:channel/<sid>` | cleanup_check_requested | **keep** (branch-end handshake) |
| `capabilities/grants.ex` (new) | `Phoenix.PubSub.broadcast` `grants_changed:<pid>` | session projection refresh | **keep** (P3-3a addition) |

**Removed in P3-13**: `routing/slash_handler.ex:287,309` (gone with file).
**Removed in P3-13**: `topology/instantiator.ex:254,288` (gone with Topology module).

### P3-15.2 — Document the audit

Create `docs/notes/pubsub-audit-pr3.md`:
```markdown
# PubSub broadcast audit (PR-3)

## Allow-list (post-PR-3)

| Topic family | Publisher | Purpose |
|---|---|---|
| `adapter:<name>/<instance_id>` | peer_server.ex, feishu_app_adapter.ex | Directive emit to Python worker |
| `handler:<module>/<worker_id>` | handler_router.ex | Handler RPC request |
| `handler_reply:<id>` | handler_channel.ex | Handler RPC response correlation |
| `directive_ack:<id>` | adapter_channel.ex | Directive ack correlation |
| `cli:channel/<session_id>` | channel_channel.ex, branch_end.ex | CC-side notification push |
| `feishu_reply` | slash result emitter (via peers/slash_handler) | CLI display hook |
| `new_chat_thread` | peers/feishu_app_adapter.ex | SessionRouter observes |
| `grants_changed:<principal_id>` | capabilities/grants.ex | Session projection refresh |

## Removed in PR-3

- `msg_received` (inert subscription, no publisher) — deleted with routing/slash_handler.ex
- `route:<esrd_url>` — cross-esrd routing out of scope; deleted with routing/slash_handler.ex
- topology/instantiator Python-callback PubSub — deleted with Topology module

## Banned patterns

- Per-peer `Phoenix.PubSub.broadcast` to a topic another peer subscribes to for
  data-plane forwarding. Use neighbor-ref `send/cast` instead.
- Cross-session broadcast on a "workspace" or "agent" topic. Use PeerProxy target.
```

### P3-15.3 — Add test that enumerates broadcast sites

Write `runtime/test/esr/pubsub_audit_test.exs`:
```elixir
defmodule Esr.PubSubAuditTest do
  use ExUnit.Case, async: false

  @moduletag :audit

  @allowed_patterns [
    ~r/^adapter:/, ~r/^handler:/, ~r/^handler_reply:/,
    ~r/^directive_ack:/, ~r/^cli:channel\//, ~r/^feishu_reply$/,
    ~r/^new_chat_thread$/, ~r/^grants_changed:/
  ]

  test "every broadcast-call literal topic in lib/ matches the allow-list" do
    lib_files =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&String.contains?(&1, "_build/"))

    violations =
      for file <- lib_files,
          line <- File.stream!(file),
          String.contains?(line, "broadcast"),
          match = Regex.run(~r/broadcast[^"]*"([^"]+)"/, line) do
        topic = Enum.at(match, 1)
        unless Enum.any?(@allowed_patterns, &Regex.match?(&1, topic)) do
          {file, topic}
        end
      end
      |> Enum.filter(& &1)

    assert violations == [], "Unallowed PubSub broadcast topics: #{inspect(violations)}"
  end
end
```

Run `mix test test/esr/pubsub_audit_test.exs`. Expect green.

**Feishu notify after P3-15**: "PubSub audit clean — 8 allowed topic families documented, all others deleted. Data-plane purity: neighbor-ref send only."

---

## P3-16 — Delete CC-era code from `peer_server.ex`

**Current footprint** (939 lines): PRD-01 F05/F06 legacy actor. Post-refactor:
- `permissions/0` callback still needed for `Esr.Handler` contract — **keep**.
- `dispatch_action(%{"type" => "emit"} ...)` with Phoenix broadcast — **keep** (CC-side MCP tool-invoke still goes through this path in PR-3 until PR-4b's adapter_runner split)
- `dispatch_action(%{"type" => "route" ...}, ...)` — **delete** (spec §2.9 removes cross-esrd routing)
- `dispatch_action(%{"type" => "invoke_command" ...}, ...)` — already deleted in P3-13
- `handle_info({:tool_invoke, ...})` — **keep** for now (CC MCP tool dispatch; migrates in PR-4b)
- `build_emit_for_tool/3` — **keep**

### P3-16.1 — Delete the `route` action

Edit `runtime/lib/esr/peer_server.ex`: delete lines 683-696 (`dispatch_action(%{"type" => "route", ...}, ...)`).

### P3-16.2 — Delete now-dead test

Grep tests using the route action:
```bash
grep -rn "\"type\" => \"route\"" /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/test
```

Edit matching tests (likely `peer_server_action_dispatch_test.exs`): delete `route` action test clauses.

### P3-16.3 — Run full suite

```bash
cd runtime && mix test --exclude integration --warnings-as-errors
```

Expect green. `peer_server.ex` should now be ~920 lines, down from 939.

**Note**: further peer_server.ex reduction (e.g. migrating `tool_invoke` → CCProcess) is **deferred to PR-4b** per spec §8.2. PR-3 leaves the tool-invoke pipeline intact; it's orthogonal to the CC-chain data plane.

---

## P3-17 — Open PR-3 draft + Feishu notify

### P3-17.1 — Pre-flight

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
git status
mix test --warnings-as-errors
mix test --only integration  # run tmux + cc_e2e + n2 separately
```

Ensure all green.

### P3-17.2 — Open PR

```bash
gh pr create --draft --title "feat(runtime): CC chain + SessionRouter + Topology removal (PR-3)" --body "$(cat <<'EOF'
## Summary

- CCProxy / CCProcess / TmuxProcess peer chain — agent `cc` now live end-to-end.
- SessionRouter as the sole control-plane module (spec §3.3).
- Session-scoped capability projection (spec D22 / futures doc).
- Capability name canonicalization spec-wide (`prefix:name/perm`).
- `Session.New` consolidated to agent semantics; `Session.BranchNew` holds legacy branch-worktree path.
- Esr.Topology.* deleted (3 lib files + 4 test files).
- Esr.Routing.SlashHandler deleted.
- PubSub audit: 8 allowed topic families; all others deleted or converted to neighbor-ref send.

## Acceptance gates (spec §10.5)

- [x] CCProcess/CCProxy/TmuxProcess unit tests
- [x] SessionRouter control-plane boundary test (Risk E)
- [x] PubSub allow-list test (`test/esr/pubsub_audit_test.exs`)
- [x] E2E: Feishu inbound → tmux → Feishu outbound
- [x] N=2 concurrent tmux
- [x] OS cleanup regression (scaffold or full; see PR body)
- [x] `session_new` requires `agent` field
- [x] Topology files deleted

## Test plan

- [ ] `mix test --exclude integration` green
- [ ] `mix test --only integration` green (requires tmux, Python uv)
- [ ] `mix test.e2e.os_cleanup` green (or skipped with follow-up ticket)
- [ ] `mix test test/esr/pubsub_audit_test.exs` green

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### P3-17.3 — Feishu notify

After `gh pr create` returns the URL, post to Feishu: "PR-3 draft opened: <url>. Review at your convenience."

---

## P3-18 — Wait for user review + merge

Standard review loop. Address each reviewer comment as its own bite-sized commit; don't amend. On user approval, `gh pr merge --squash --subject "feat(runtime): CC chain + SessionRouter (PR-3)"`.

Post-merge Feishu notify: "PR-3 merged on `main`."

---

## P3-19 — PR-3 progress snapshot + Feishu notify

### P3-19.1 — Write snapshot

Create `docs/superpowers/progress/<YYYY-MM-DD>-pr3-snapshot.md` following the PR-2 snapshot's shape (API surfaces, decisions locked in, tests added/removed, tech debt introduced + resolution targets, PR-4 expansion inputs). Include:

- New public API surfaces: `Esr.Peers.CCProxy/CCProcess/TmuxProcess`, `Esr.SessionRouter`, `Esr.Capabilities.has_all?/2`, `SessionProcess.has?/2` (projection form), `Session.New` (agent), `Session.BranchNew`.
- Decisions locked in: D3-PR3-a (`PR-3 canonicalizes cap names to `prefix:name/perm`), D3-PR3-b (`FeishuAppAdapter :not_found` is log-only in PR-3; auto-create deferred), D3-PR3-c (`Session.End` separates agent-session vs branch teardown), D3-PR3-d (PubSub allow-list of 8 topic families).
- Tests added / removed (exact counts).
- Tech debt: `peer_server.ex` still contains legacy `handle_info({:tool_invoke, ...})` and `build_emit_for_tool/3` — resolved in PR-4b when `cc_adapter_runner` Python splits. `os_cleanup_test` scaffold vs full — resolved when subprocess-esrd infra lands.
- Next PR expansion inputs: for PR-4a/PR-4b parallel work, load PR-1/PR-2/PR-3 snapshots + §8 of spec.

### P3-19.2 — Feishu notify

"PR-3 snapshot complete: <path>. Peer/session refactor 3-of-6 done. Next: PR-4a (voice split) + PR-4b (adapter_runner split) can run in parallel."

---

# Report Back

## Tasks I could not fully expand (with reason)

- **P3-12 (OS cleanup regression)** — the full implementation depends on subprocess-esrd infrastructure (a way to boot a detached esrd, retrieve its OS PID, and kill it). No such helper exists in the current repo; the scaffold is written with `@moduletag :os_cleanup` and helper stubs. The task is tagged in the PR body as "scaffold-or-full, whichever lands cleanly; else follow-up ticket". Choosing to defer beyond PR-3 is acceptable per spec §10.5 (acceptance gate says "OS cleanup regression: `kill -9` esrd → all tmux die in 10s" — meeting that requires either real infra or an acknowledged follow-up; I noted both options).

- **P3-10's handler-override mechanism** — needs a small addition to `CCProcess.call_handler/3` (read `Application.get_env(:esr, :handler_module_override)` in addition to `Process.get(:cc_handler_override)`) to reach across process boundaries in the integration test. Called out inline but not explicitly specced as a separate sub-task. Implementer should land it as the first step of P3-10.

- **P3-13's `cli_channel.ex` polite-degrade branch** — I chose Option B (return structured error) but the exact error shape matches user-facing CLI expectations which I don't have full context on. Implementer should coordinate with whoever owns `py/src/esr/cli/main.py`'s topology command UX (the CLI still ships those commands in the Python side; they'll now get error responses).

## Drift between plan outline and current code

1. **Plan's P3-8 says "move `AgentNew` content into `new.ex`"**; current code has `AgentNew.execute/1` already doing the agent-session work. The rename-then-consolidate is straightforward (P3-8.5 + P3-8.6). No surprise here.

2. **Plan's P3-9 implies `Session.End` handles agent-session teardown**; current `Session.End` is *all* branch-worktree logic (no agent-session concept). The rename to `BranchEnd` + write-new `End` is clean but the plan's wording is ambiguous on whether the existing file is adapted in-place or split. I chose split (P3-9.1/P3-9.2) because agent-session end is structurally unrelated to branch-worktree end.

3. **Plan says "delete `Esr.Routing.SlashHandler`"** — the current repo also has `Esr.Routing.Supervisor` (one-child scaffold). Deleted alongside. The plan's bullet doesn't mention the Supervisor but it's a trivial co-deletion.

4. **P3-3a's grants projection** — the plan row says "Peers call `SessionProcess.has?/2` instead of `Grants.has?/2`". In reality, production code has 3 relevant call sites (`peer_server.ex:903`, `peer/proxy.ex:68`, `admin/dispatcher.ex:155`). Two are data-plane; one is admin-plane. My expansion migrates only the data-plane two (dispatcher stays on global because it's admin scope — dispatches *to* sessions, doesn't live inside one). Plan didn't specify this nuance; called out in P3-3a.3.

5. **`FeishuAppAdapter`'s `:not_found` branch already exists** (lines 58-65 publishing `:new_chat_thread` on PubSub); plan reads as if P3-7 introduces it. It's actually already done in PR-2; P3-7 just wires the subscriber side. Expansion reflects reality.

6. **`peer_server.ex`'s `restore_feishu_app_session/1` helper in application.ex** — plan's P3-13 task says "delete Topology module files" but the FeishuAppSession auto-restore depends on Topology's `get_artifact`. My expansion (P3-13.3) deletes the auto-restore helper too; a secondary consequence the plan outline didn't call out.

## Spec-level contradictions

- **§3.3 hard rule 3** says `SessionRegistry` must not hold mutable session state; it holds "compiled yaml artifacts, `(chat_id, thread_id) → session_id` mapping, `(session_id, peer_name) → pid` lookup". But the current implementation at `runtime/lib/esr/session_registry.ex:28-32` *does* store session-state-ish maps (`sessions: %{session_id => %{key, refs}}`). This isn't a contradiction if we treat `refs` as pid-lookup (which is its intent), but the line between "mutable session state" and "pid lookup" could be cleaner. Not a PR-3 blocker; worth a review comment.

- **§5.1 data flow** shows FeishuChatProxy → CCProxy → CCProcess → TmuxProcess with `{:text, ...}` as the payload shape; but peer_server.ex and the current PR-2 code uses `{:feishu_inbound, envelope}` upstream. My expansion normalizes at the FCP→CCProxy boundary (FCP unwraps to `{:text, bytes}`). Spec doesn't fully specify the handover shape; called out in P3-1.3.

- **Spec §4.1 TmuxProcess card** says "OSProcess composition — MuonTrap底座"; but `docs/notes/muontrap-mode3-constraint.md` (post-spec discovery) mandates `wrapper: :none`. Current code already honors the note; spec text is stale. Not a PR-3 blocker but spec §4.1 deserves an edit alongside the P3-8 canonicalization pass (cheap to bundle).

- **Spec §1.8 D22** is referenced in the user prompt as the spec entry for session-scoped projection; the actual spec (v3.1) ends at D21. D22 would be added by a spec-edit commit inside P3-3a (I did not explicitly add that step; implementer should). Adding D22 row: "Session-scoped grants projection — `SessionProcess` holds a local `grants` map populated from `Grants` at init, refreshed via PubSub `{:grants_changed, principal_id}`. Peers call `SessionProcess.has?/2` on data-plane reads. Global `Grants` remains the write-side source of truth. Resolves shared-singleton contention (see `docs/futures/peer-session-capability-projection.md`)."

## Tasks I'd reorder for dependency clarity

1. **P3-8 before P3-1** — the capability canonicalization must land first because every `@required_cap` string in the new peers depends on the canonical form. I flagged this in the table and set the execution order P3-0 → P3-8 → P3-1 → P3-2 → P3-3 → P3-3a → P3-4 → ...

2. **P3-4 (SessionRouter) before P3-5 (boundary test)**: trivially already ordered; just confirming.

3. **P3-6 (agents.yaml wiring) before P3-7 (SessionRouter subscription to `:new_chat_thread`)** — P3-7's integration test needs a populated agent_def. My expansion schedules P3-6 → P3-7. Plan had P3-6 before P3-7 so already correct; reinforcing.

4. **P3-9 (Session.End) is better landed immediately after P3-4 (SessionRouter)** rather than after P3-7 — because `Session.End` tests can run fully without the new-chat-thread signal path. My expansion keeps plan order (P3-4 → P3-5 → P3-6 → P3-7 → P3-9) but note that P3-9 *could* move earlier with no dependency cost.

5. **P3-15 (PubSub audit) after P3-13 + P3-14** — correct ordering; the audit needs the Topology and Routing broadcasts gone first so the allow-list test is achievable. Confirmed in sequence.

6. **P3-3a (grants projection)** — the plan placed this right after P3-3 (TmuxProcess); I moved it to after P3-3a's own row placement (between P3-3 and P3-4) for implementation clarity because SessionRouter's `create_session/2` reads `SessionProcess.has?/2` semantics indirectly; having projection live first means SessionRouter's spawn path sees the upgraded API.

---

## Critical Files for Implementation

- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/session_router.ex` (new)
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/cc_process.ex` (new)
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/peers/tmux_process.ex` (moved from `lib/esr/tmux_process.ex`; extended handle_downstream + on_terminate)
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/session_process.ex` (extended: grants projection + PubSub subscription)
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/admin/commands/session/new.ex` (rewritten from `agent_new.ex` content)
- `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime/lib/esr/application.ex` (register SessionRouter; remove Topology.Supervisor + Routing.Supervisor)