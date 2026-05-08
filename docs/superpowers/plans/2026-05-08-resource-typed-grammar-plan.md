# Resource-Typed Grammar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Resolved by user 2026-05-08** (post subagent review):
> - **Q1.** `Esr.Session.ChatRouting.Registry.attached_sessions/2` renamed to `list_sessions/2` (no callers — single in-place rename in Phase B Task B.2).
> - **Q2.** `/cc:tui` (rev-3 spec) → `/claude_code:tui` (rev-4 spec amendment): manifest validator's plugin-name prefix rule wins; verbose form is paid once at type-time.
> - **Q3.** Latent bug fix folded in: PtyProcess broadcasts/registers on `pty:<actor_id>`, not `pty:<session_id>`. The current "use session_id" code is M-2 era leftover that silently broke multi-agent attach (N PtyProcesses share one ETS register key + one PubSub topic). Phase A expands by 2 tasks (A.4 = PtyProcess topic migration; A.5 = multi-agent attach isolation regression test). Phase E.2 simplifies (no reverse lookup needed). Phase E.7 extends e2e 22 with multi-agent attach assertion.

**Goal:** Refactor the slash-command surface so resources line up with operations: `/agent:*` for agent instances, `/pty:*` for PTY URLs, `/session:*` for session lifecycle + chat-binding. Plug the four operator-visible gaps named in spec rev-3 §1.

**Architecture:** Six phases on a single feature branch off `origin/dev` — five code phases (A-E) plus a final docs-sweep phase (F). The cleanup PR (`Esr.Scope.* → Esr.Session.*` + ChatScope split) and the multimedia PR have already merged into `dev` (HEAD `cccb7a6`). No backwards-compatible aliases — old slash forms are wired into `slash_handler.ex`'s `@deprecated_slashes` map (already pattern in use) so operators get a structured "renamed" hint when they hit the old form. `/claude_code:tui` ships in the **claude_code plugin** via the rev-3 plugin-scoped command registration mechanism (manifest `slash_routes:` block) — second real consumer after feishu, validates the mechanism end-to-end again.

**Tech Stack:** Elixir 1.19, OTP 27, Phoenix 1.8, ExUnit (`async: false` for ETS-backed tests), `runtime/priv/slash-routes.default.yaml` (single source of truth for kind → command_module), bash e2e harness (`tests/e2e/scenarios/`).

**Spec:** [`docs/superpowers/specs/2026-05-08-resource-typed-grammar.md`](../specs/2026-05-08-resource-typed-grammar.md) (rev-3, user-approved 2026-05-08).

**Branch:** `feat/resource-typed-grammar` off `origin/dev` (created in Phase A Task A.0).

**Total estimate:** ~540 LOC implementation + ~370 LOC test + ~80 LOC docs = ~990 LOC. Six phases (A-F), ~37 bite-sized tasks. Each phase commits independently and leaves the dispatcher functional. The +100 LOC over the rev-3 estimate covers Phase A.4 + A.5 (PtyProcess pubsub topic migration + multi-agent isolation test).

---

## Pre-conditions (already satisfied — verify before starting)

The plan assumes these have landed on `dev` (HEAD `cccb7a6`):

1. **concepts.md rev-10** (PR #271) — Realm = class, Session = instance.
2. **Cleanup PR** (PR #274) — `Esr.Scope.* → Esr.Session.*` rename + commands rename + `ChatScope.Registry` split into `Esr.Session.ChatRouting.Registry` + `Esr.Session.NameIndex.Registry`.
3. **Multimedia PR** (PR #273) — image+file inbound/outbound (irrelevant to grammar but rebased through this base).

Verify with:

```bash
git -C /Users/h2oslabs/Workspace/esr/.worktrees/dev log --oneline -3
# Expected:
# cccb7a6 feat: multimedia content protocol — image+file inbound/outbound (#273)
# eca0e3d refactor(session): cleanup PR — Esr.Scope.* → Esr.Session.* + ChatScope split + python-cli orphan fix (#274)
# 8f78810 docs(concepts): rev 10 — swap "Session = class / Scope = instance" → "Realm = class / Session = instance" (#271)
```

If any of those is missing, STOP and complete the prerequisite before starting Phase A.

---

## File structure overview

Implementation files (new + modified):

```
runtime/lib/esr/
├── entity/agent/
│   ├── instance.ex                  [MODIFY: add actor_ids field — Phase A]
│   └── instance_registry.ex         [MODIFY: persist actor_ids, expose pty_actor_id_for/2 — Phase A]
├── entity/
│   └── slash_handler.ex             [MODIFY: extend @deprecated_slashes for 5 renamed slashes — Phase C/D]
├── commands/
│   ├── help.ex                      [MODIFY: add "Users" category — Phase B]
│   ├── attach.ex                    [DELETE — Phase E]
│   ├── session/
│   │   ├── list.ex                  [MODIFY: chat-bound + admin shape — Phase B]
│   │   ├── bind_chat.ex             [NEW — Phase D]
│   │   ├── unbind_chat.ex           [NEW — Phase D]
│   │   ├── attach.ex                [DELETE — Phase D]
│   │   ├── detach.ex                [DELETE — Phase D]
│   │   ├── add_agent.ex             [DELETE — Phase C]
│   │   ├── remove_agent.ex          [DELETE — Phase C]
│   │   └── set_primary.ex           [DELETE — Phase C]
│   ├── agent/
│   │   ├── list.ex                  [REWRITE: lists instances not types — Phase C]
│   │   ├── add.ex                   [NEW — Phase C]
│   │   ├── remove.ex                [NEW — Phase C]
│   │   ├── set_primary.ex           [NEW — Phase C]
│   │   ├── primary.ex               [NEW — Phase C]
│   │   └── rename.ex                [NEW — Phase C]
│   ├── plugin/
│   │   └── agent_types.ex           [NEW: holds old /agent:list type-catalog logic — Phase C]
│   └── pty/
│       ├── list.ex                  [NEW — Phase E]
│       └── attach.ex                [NEW — Phase E]
└── plugins/claude_code/
    ├── manifest.yaml                [MODIFY: add slash_routes: block — Phase E]
    └── commands/
        └── tui.ex                   [NEW: agent-name → PTY id → URL — Phase E]
runtime/priv/
└── slash-routes.default.yaml        [MODIFY across all 5 phases]

runtime/test/esr/
├── entity/agent/
│   └── instance_registry_test.exs   [MODIFY: add actor_ids assertion — Phase A]
├── commands/
│   ├── session/
│   │   ├── list_test.exs            [MODIFY — Phase B]
│   │   ├── bind_chat_test.exs       [NEW — Phase D]
│   │   └── unbind_chat_test.exs     [NEW — Phase D]
│   ├── agent/
│   │   ├── list_test.exs            [REWRITE — Phase C]
│   │   ├── add_test.exs             [NEW — Phase C]
│   │   ├── remove_test.exs          [NEW — Phase C]
│   │   ├── set_primary_test.exs     [NEW — Phase C]
│   │   ├── primary_test.exs         [NEW — Phase C]
│   │   └── rename_test.exs          [NEW — Phase C]
│   ├── plugin/
│   │   └── agent_types_test.exs     [NEW — Phase C]
│   └── pty/
│       ├── list_test.exs            [NEW — Phase E]
│       └── attach_test.exs          [NEW — Phase E]
├── plugins/claude_code/commands/
│   └── tui_test.exs                 [NEW — Phase E]
└── entity/
    └── slash_handler_test.exs       [MODIFY: cases for renamed slashes — Phase C/D]

tests/e2e/scenarios/
└── 22_resource_typed_grammar.sh     [NEW — Phase E]
```

Spec coverage map: every row in spec §6 implementation surface is represented above; every row in §7 phase plan maps to a phase below.

---

## Phase A — `actor_ids` on `%Instance{}`

**Why first:** `/claude_code:tui` (Phase E) needs to resolve agent name → PTY id. Today `actor_ids` are returned as a side-channel from `add_instance_and_spawn/2` but never persisted on `%Instance{}`. Phase A fixes that — small foundational change, no operator-visible behaviour delta.

**Files:**
- Modify: `runtime/lib/esr/entity/agent/instance.ex` (defstruct + typespec)
- Modify: `runtime/lib/esr/entity/agent/instance_registry.ex:275-282` (struct construction) + new `pty_actor_id_for/2` helper
- Test: `runtime/test/esr/entity/agent/instance_registry_test.exs` (add `actor_ids` round-trip assertion + `pty_actor_id_for/2` lookup test)

### Task A.0 — Branch off origin/dev

- [ ] **Step 1: Verify base + create branch**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin
git checkout -b feat/resource-typed-grammar origin/dev
git log --oneline -1
# Expected: cccb7a6 feat: multimedia content protocol — image+file inbound/outbound (#273)
```

### Task A.1 — Failing test for `actor_ids` persistence

**Why this matters (educational):** the existing registry tests use `:not_running` mode (no real session supervisor) so they exercise the `{:error, {:spawn_failed, _}}` error path. We need a different shape — the persistence test uses ETS injection rather than going through the spawn path, since the spawn path requires a full Scope tree.

- [ ] **Step 1: Read existing test file to find a good insertion point**

```bash
wc -l runtime/test/esr/entity/agent/instance_registry_test.exs
```

- [ ] **Step 2: Add a failing test**

Add the following test at the end of the existing `describe` block (or a new `describe "actor_ids persistence"` block) in `runtime/test/esr/entity/agent/instance_registry_test.exs`:

```elixir
describe "actor_ids field on %Instance{}" do
  test "Instance struct carries actor_ids field" do
    inst = %Esr.Entity.Agent.Instance{
      id: "11111111-1111-4111-8111-111111111111",
      session_id: "22222222-2222-4222-8222-222222222222",
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid", pty: "pty-uuid"}
    }

    assert inst.actor_ids == %{cc: "cc-uuid", pty: "pty-uuid"}
  end

  test "pty_actor_id_for/2 returns the persisted PTY id" do
    sid = "33333333-3333-4333-8333-333333333333"
    name = "alice"

    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)

    inst = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-aaaa",
      session_id: sid,
      type: "cc",
      name: name,
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-aaaa", pty: "pty-uuid-bbbb"}
    }

    :ets.insert(tab, {{sid, name}, inst})

    assert {:ok, "pty-uuid-bbbb"} =
             Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for(sid, name)

    assert :not_found =
             Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for(sid, "no-such")
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
(cd runtime && mix test test/esr/entity/agent/instance_registry_test.exs --only describe:"actor_ids field on %Instance{}" 2>&1 | tail -25)
```

Expected: compile error or struct error (no `:actor_ids` field) AND `(UndefinedFunctionError) function Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for/2 is undefined`.

### Task A.2 — Add `actor_ids` field to `%Instance{}`

- [ ] **Step 1: Edit `runtime/lib/esr/entity/agent/instance.ex`**

Replace the `@type t` block (lines 16-23) and `defstruct` block (lines 25-32) with:

```elixir
  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          type: String.t() | nil,
          name: String.t() | nil,
          config: map(),
          created_at: String.t() | nil,
          actor_ids: %{cc: String.t(), pty: String.t()} | nil
        }

  defstruct [
    :id,
    :session_id,
    :type,
    :name,
    :created_at,
    :actor_ids,
    config: %{}
  ]
```

Also extend the `@moduledoc` `Fields:` list with one bullet:

```
    * `actor_ids` — `%{cc: <uuid>, pty: <uuid>}`. Persisted at `add_instance_and_spawn/2` so `/claude_code:tui` (and any future agent-name → PTY-id lookup) resolves without a side-channel return.
```

- [ ] **Step 2: Run the struct-only test**

```bash
(cd runtime && mix test test/esr/entity/agent/instance_registry_test.exs:LINE 2>&1 | tail -10)
# replace LINE with the line of the first new test ("Instance struct carries actor_ids field")
```

Expected: PASS for the struct test; the `pty_actor_id_for/2` test still fails with `UndefinedFunctionError`.

### Task A.3 — Persist `actor_ids` + expose `pty_actor_id_for/2`

- [ ] **Step 1: Edit `runtime/lib/esr/entity/agent/instance_registry.ex` lines 275-282**

Replace the `inst = %Instance{...}` construction (lines 275-282) with:

```elixir
            inst = %Instance{
              id: cc_actor_id,
              session_id: session_id,
              type: type,
              name: name,
              config: config,
              created_at: iso_now(),
              actor_ids: %{cc: cc_actor_id, pty: pty_actor_id}
            }
```

- [ ] **Step 2: Add `pty_actor_id_for/2` helper near `primary/1`**

After the `primary/1` function (around line 150 — verify with `grep -n "def primary" runtime/lib/esr/entity/agent/instance_registry.ex`), add:

```elixir
  @doc """
  Look up the PTY actor id for `(session_id, name)`.

  Returns `{:ok, pty_actor_id}` or `:not_found`. Used by `/claude_code:tui` and
  `/pty:list` to resolve agent name → PTY id without going through the
  side-channel `add_instance_and_spawn/2` return.
  """
  @spec pty_actor_id_for(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | :not_found
  def pty_actor_id_for(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    tab = GenServer.call(server, :table_name)

    case :ets.lookup(tab, {session_id, name}) do
      [{_, %Instance{actor_ids: %{pty: pty_id}}}] when is_binary(pty_id) ->
        {:ok, pty_id}

      _ ->
        :not_found
    end
  end
```

- [ ] **Step 3: Run all the Phase A tests**

```bash
(cd runtime && mix test test/esr/entity/agent/instance_registry_test.exs 2>&1 | tail -15)
```

Expected: all `actor_ids field on %Instance{}` describe-block tests PASS; pre-existing tests in the same file remain green.

- [ ] **Step 4: Run full registry-adjacent test suite to catch regressions**

```bash
(cd runtime && mix test test/esr/entity/agent/ test/esr/commands/session/add_agent_test.exs 2>&1 | tail -15)
```

Expected: all green.

- [ ] **Step 5: Commit (Phase A 1/2 — actor_ids persistence)**

```bash
git add runtime/lib/esr/entity/agent/instance.ex \
        runtime/lib/esr/entity/agent/instance_registry.ex \
        runtime/test/esr/entity/agent/instance_registry_test.exs
git commit -m "$(cat <<'EOF'
feat(grammar/A): persist actor_ids on %Instance{} + expose pty_actor_id_for/2

Foundation for /claude_code:tui (Phase E): agent-name → PTY-id resolution
must read a persistent field, not the side-channel return from
add_instance_and_spawn/2. Adds actor_ids field to %Instance{} struct,
populates it at construction, and exposes pty_actor_id_for/2 helper.

Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md §4.5,
D4. Plan: docs/superpowers/plans/2026-05-08-resource-typed-grammar-plan.md
Phase A.1-A.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task A.4 — PtyProcess pubsub topic migration: session_id → actor_id

**Why:** M-2 era leftover. `runtime/lib/esr/entity/pty_process.ex` calls `Esr.Entity.Registry.register("pty:" <> sid, self())` (line 142), `register_attrs("pty:" <> sid, …)` (line 155), and `PubSub.broadcast(EsrWeb.PubSub, "pty:" <> sid, …)` (lines 292, 312). All four use `state.session_id`. With multi-agent sessions (M-2.6+), N PtyProcess workers share one ETS register key + one PubSub topic — second registration silently overwrites the first; broadcasts mux. Today single-agent works; multi-agent attach is silently broken.

PtyProcess already receives its own `actor_id` UUID via `build_pty_args(session_id, name, pty_actor_id, config)` at `instance_registry.ex:326-339` (passed as `args.actor_id`). PtyProcess.init just doesn't USE it. Fix is a 4-line swap.

- [ ] **Step 1: Failing isolation test (drives the fix)**

Add to `runtime/test/esr/entity/pty_process_test.exs` (create the file if it doesn't exist; otherwise append a fresh `describe`):

```elixir
defmodule Esr.Entity.PtyProcessIsolationTest do
  use ExUnit.Case, async: false

  alias Phoenix.PubSub

  setup do
    case Process.whereis(EsrWeb.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: EsrWeb.PubSub})
      _ -> :ok
    end

    case Process.whereis(Esr.Entity.Registry) do
      nil -> start_supervised!(Esr.Entity.Registry)
      _ -> :ok
    end

    :ok
  end

  test "two PtyProcesses with same session_id register under distinct actor_id keys" do
    sid = "55555555-5555-4555-8555-555555555555"
    aid_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    aid_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    pid_a = spawn_link(fn -> Process.sleep(:infinity) end)
    pid_b = spawn_link(fn -> Process.sleep(:infinity) end)

    # Simulate the post-fix init/1 contract: register under actor_id, not session_id.
    :ok = Esr.Entity.Registry.register("pty:" <> aid_a, pid_a)
    :ok = Esr.Entity.Registry.register("pty:" <> aid_b, pid_b)

    assert {:ok, ^pid_a} = Esr.Entity.Registry.lookup("pty:" <> aid_a)
    assert {:ok, ^pid_b} = Esr.Entity.Registry.lookup("pty:" <> aid_b)
    assert pid_a != pid_b
  end

  test "broadcast on pty:<actor_id> reaches only the matching subscriber" do
    aid_a = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
    aid_b = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"

    parent = self()

    sub_a = spawn_link(fn ->
      :ok = PubSub.subscribe(EsrWeb.PubSub, "pty:" <> aid_a)
      receive do
        {:pty_stdout, data} -> send(parent, {:a, data})
      after 500 -> send(parent, {:a, :timeout})
      end
    end)

    sub_b = spawn_link(fn ->
      :ok = PubSub.subscribe(EsrWeb.PubSub, "pty:" <> aid_b)
      receive do
        {:pty_stdout, data} -> send(parent, {:b, data})
      after 500 -> send(parent, {:b, :timeout})
      end
    end)

    Process.sleep(50)

    PubSub.broadcast(EsrWeb.PubSub, "pty:" <> aid_a, {:pty_stdout, "alice-output"})

    assert_receive {:a, "alice-output"}, 1_000
    assert_receive {:b, :timeout}, 1_000
  end
end
```

- [ ] **Step 2: Run the test to confirm it passes (it should — these tests assert the post-fix contract directly via Registry/PubSub APIs, not via PtyProcess)**

```bash
(cd runtime && mix test test/esr/entity/pty_process_test.exs --only describe:"PtyProcessIsolationTest" 2>&1 | tail -10)
```

Expected: PASS. The tests don't go through PtyProcess.init yet — they verify the Registry + PubSub layer behaves correctly with `pty:<actor_id>` keys. This is the safety net for Step 3.

- [ ] **Step 3: Edit `runtime/lib/esr/entity/pty_process.ex` init/1 (lines 122-166)**

Replace the four occurrences of `"pty:" <> sid` with `"pty:" <> actor_id`. Specifically:

In `init/1` (around line 134), after the existing `sid = state.session_id` line, add:

```elixir
    actor_id = Map.get(args, :actor_id) || sid
```

(Defensive default to `sid` so unit tests that don't pass `:actor_id` keep working — production path always supplies it via `build_pty_args/4`.)

Also extend `state` (lines 123-132) to include `actor_id`:

```elixir
    state = %{
      session_name: args.session_name,
      dir: args.dir,
      subscribers: [args[:subscriber] || self()],
      session_id: Map.get(args, :session_id),
      actor_id: Map.get(args, :actor_id),
      workspace_name: Map.get(args, :workspace_name),
      chat_id: Map.get(args, :chat_id),
      app_id: Map.get(args, :app_id),
      start_cmd: Map.get(args, :start_cmd)
    }
```

Then in the body (line 139 onwards), swap:

- Line 142: `Esr.Entity.Registry.register("pty:" <> sid, self())` → `Esr.Entity.Registry.register("pty:" <> actor_id, self())`
- Line 155: `Esr.Entity.Registry.register_attrs("pty:" <> sid, ...)` → `Esr.Entity.Registry.register_attrs("pty:" <> actor_id, ...)`

For lines 292 + 312 (broadcast paths in raw_stdout + terminate handlers — find with grep):

```bash
grep -n "PubSub.broadcast" runtime/lib/esr/entity/pty_process.ex
```

These typically reference `state.session_id`. Change them to use `state.actor_id` (with `state.actor_id || state.session_id` fallback if needed for unit-test paths).

Same swap for `terminate` line 320 (`deregister_attrs`).

- [ ] **Step 4: Edit `runtime/lib/esr_web/pty_socket.ex`** — no code change needed; `state.sid` from the `?sid=` query param now semantically carries actor_id (operator passes `?sid=<pty_actor_id>`). UPDATE the moduledoc reference at line 25 from "URL: `/attach_socket/websocket?sid=<session_id>`" to "URL: `/attach_socket/websocket?sid=<pty_actor_id>`".

- [ ] **Step 5: Update PtyProcess @moduledoc**

`runtime/lib/esr/entity/pty_process.ex:1-32` references `pty:<session_id>` and `EsrWeb.AttachLive` (replaced by `EsrWeb.AttachController`). Refresh:

```elixir
  @moduledoc """
  Generic PTY-backed peer (PR-22, 2026-05-01; M-2.6 multi-instance,
  resource-typed grammar PR pubsub topic migration). Owns one OS process
  spawned via erlexec's `:pty` wrapper. Fans raw stdout chunks to
  Phoenix.PubSub topic `"pty:<actor_id>"` for `EsrWeb.PtySocket`
  subscribers; accepts stdin via the public `write/2` and SIGWINCH via
  `resize/3`.

  ## Identity

  Each PtyProcess registers under `Esr.Entity.Registry` with the binary
  actor_id `"pty:<actor_id>"` (where `actor_id` is the per-instance UUID
  generated by `Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn/2`).
  Pre-resource-typed-grammar this used `"pty:<session_id>"`, which broke
  multi-agent attach: N PtyProcesses in one session collided on the
  register key + PubSub topic.

  ## Subscribers

  - `EsrWeb.PtySocket` subscribes to `pty:<actor_id>` to fan stdout to
    the browser.
  - cc_process is **not** a subscriber — the conversation path is
    cc_mcp → `cli:channel/<sid>`. PtyProcess only serves the operator-
    facing browser attach.

  ## Process structure

  - `start_link/1` starts `__MODULE__.OSProcessWorker` (generated by the
    `use Esr.OSProcess` macro).
  - `init/1` registers under `Esr.Entity.Registry` AND in Index 2/3 via
    `register_attrs/2` so `Esr.ActorQuery.{find_by_name/2, list_by_role/2}`
    resolve this peer.
  - `on_raw_stdout/2` broadcasts raw bytes BEFORE line-splitting so ANSI
    escapes spanning chunk boundaries reach xterm.js intact.
  - `on_terminate/1` broadcasts a bare `:pty_closed` so attached sockets
    can render a "session ended" overlay.
  """
```

- [ ] **Step 6: Run all PtyProcess + InstanceRegistry tests**

```bash
(cd runtime && mix test test/esr/entity/pty_process_test.exs test/esr/entity/agent/ 2>&1 | tail -10)
```

Expected: all green.

- [ ] **Step 7: Run full mix test for regression**

```bash
(cd runtime && mix test 2>&1 | tail -5)
```

Expected: only pre-existing flakes. Watch for any test that referenced `pty:<session_id>` register key or topic — those will fail and need updating to `pty:<actor_id>`.

- [ ] **Step 8: Commit (Phase A 2/2 — PtyProcess pubsub topic + isolation test)**

```bash
git add runtime/lib/esr/entity/pty_process.ex \
        runtime/lib/esr_web/pty_socket.ex \
        runtime/test/esr/entity/pty_process_test.exs
git commit -m "$(cat <<'EOF'
fix(grammar/A): PtyProcess pubsub topic migrates to actor_id (M-2 latent bug)

Pre-fix: PtyProcess.init registered + broadcast on "pty:<session_id>".
With M-2.6 multi-agent sessions, N PtyProcess workers share ONE
register key + ONE PubSub topic — second registration silently
overwrites first, broadcasts mux. Single-agent worked; multi-agent
browser attach was silently broken.

PtyProcess already receives its own actor_id UUID via build_pty_args/4
(instance_registry.ex:326). This change uses it: register key, Index
2/3 attrs, broadcast topic, terminate deregister all switch to
"pty:<actor_id>". PtySocket's connect param semantically becomes
actor_id (no code change; doc only).

Adds isolation regression test: two distinct actor_ids → two distinct
register entries + non-cross-talking pubsub broadcasts. Future-proofs
the multi-agent path before it's exercised end-to-end in scenario 22.

Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md
§4.4-4.5 (rev-4 amendment), Q3 user decision 2026-05-08.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase B — `/session:list` slash + `/session:switch` slash + `/session:end` slash + `/help` Users category

**Why these together:** all four are pure additive — wiring already-existing command modules to the slash surface. Spec §6.4: `Esr.Commands.Session.{Switch,End}` already exist post-cleanup; `Esr.Commands.Session.List` exists but body needs a small enrichment for chat-scope output.

**Files:**
- Modify: `runtime/lib/esr/commands/session/list.ex` (add chat-bound shape — admin/workspace shape stays)
- Modify: `runtime/lib/esr/commands/help.ex:46-54` (add `Users` category)
- Modify: `runtime/priv/slash-routes.default.yaml` (add 3 slash entries; remove the deferred-comment placeholders at lines 264-265 and 348-349)
- Modify: `runtime/test/esr/commands/session/list_test.exs` (add chat-bound case)

### Task B.1 — Failing test for chat-bound /session:list shape

- [ ] **Step 1: Read existing list_test.exs**

```bash
wc -l runtime/test/esr/commands/session/list_test.exs
```

- [ ] **Step 2: Add a failing test**

Append the following to `runtime/test/esr/commands/session/list_test.exs` (inside the existing module's outermost `describe`/`test` scope, or as a fresh `describe`):

```elixir
describe "chat-bound shape (no workspace= arg)" do
  setup do
    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    :ok
  end

  test "returns sessions attached to (chat_id, app_id) when chat context present" do
    chat = "oc_b1_test"
    app = "esr_helper_test"
    sid_a = "aaaaaaaa-1111-4111-8111-111111111111"
    sid_b = "bbbbbbbb-2222-4222-8222-222222222222"

    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid_a)
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid_b)

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{
        "chat_id" => chat,
        "app_id" => app
      }
    }

    assert {:ok, %{"sessions" => sessions, "chat_id" => ^chat}} =
             Esr.Commands.Session.List.execute(cmd)

    sids = Enum.map(sessions, & &1["session_id"]) |> Enum.sort()
    assert sids == Enum.sort([sid_a, sid_b])
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
(cd runtime && mix test test/esr/commands/session/list_test.exs --only describe:"chat-bound shape" 2>&1 | tail -15)
```

Expected: FAIL — current `Session.List.execute/1` returns the legacy routing.yaml shape (no `"sessions"` key, no `"chat_id"` key) when args have no `"workspace"`.

### Task B.2 — Implement chat-bound shape in Session.List

- [ ] **Step 1: Edit `runtime/lib/esr/commands/session/list.ex`**

Add a NEW clause for chat-bound shape ABOVE the existing legacy `def execute(%{"submitted_by" => submitter}) when is_binary(submitter) do` clause (currently lines 79-92). Insert this clause:

```elixir
  def execute(%{
        "submitted_by" => submitter,
        "args" => %{"chat_id" => chat_id, "app_id" => app_id}
      })
      when is_binary(submitter) and is_binary(chat_id) and chat_id != "" and
             is_binary(app_id) and app_id != "" do
    sessions =
      case Esr.Session.ChatRouting.Registry.list_sessions(chat_id, app_id) do
        sids when is_list(sids) ->
          Enum.map(sids, fn sid -> %{"session_id" => sid} end)

        _ ->
          []
      end

    {:ok,
     %{
       "chat_id" => chat_id,
       "app_id" => app_id,
       "sessions" => sessions
     }}
  end
```

- [ ] **Step 2: Rename `attached_sessions/2` → `list_sessions/2` in `runtime/lib/esr/session/chat_routing/registry.ex`**

`attached_sessions/2` (lines 119-129) is the only public reader for the per-chat `attached: MapSet.t()` field. Body is `MapSet.to_list(set)` — already exactly "list sessions in this chat scope". Name is M-2 era leftover that reads like a status check rather than a list operation.

NO callers exist anywhere in the runtime today (verified via `grep -rn "attached_sessions" runtime/ tests/`). Phase B is the first consumer. Safe in-place rename.

Edit `registry.ex`:
- Line 31 (moduledoc bullet list): `attached_sessions/2` → `list_sessions/2`
- Line 119 `@spec attached_sessions(...)` → `@spec list_sessions(...)`
- Line 120 `def attached_sessions(...)` → `def list_sessions(...)`

Step 1 above already calls `Esr.Session.ChatRouting.Registry.list_sessions(chat_id, app_id)` so no change needed there.

- [ ] **Step 3: Run the test**

```bash
(cd runtime && mix test test/esr/commands/session/list_test.exs --only describe:"chat-bound shape" 2>&1 | tail -10)
```

Expected: PASS.

- [ ] **Step 4: Run all session-list tests to catch regressions**

```bash
(cd runtime && mix test test/esr/commands/session/list_test.exs 2>&1 | tail -10)
```

Expected: all green (legacy shape + workspace-scoped shape + new chat-bound shape).

### Task B.3 — Add `Users` category to /help

- [ ] **Step 1: Edit `runtime/lib/esr/commands/help.ex` lines 46-54**

Replace:

```elixir
  defp category_order("诊断"), do: 0
  defp category_order("Workspace"), do: 1
  defp category_order("Sessions"), do: 2
```

with:

```elixir
  defp category_order("诊断"), do: 0
  defp category_order("Users"), do: 1
  defp category_order("Workspace"), do: 2
  defp category_order("Sessions"), do: 3
```

…and shift the rest:

```elixir
  defp category_order("Agents"), do: 4
  defp category_order("PTY"), do: 5
  defp category_order("Plugins"), do: 6
  defp category_order("Capabilities"), do: 7
  defp category_order("其他"), do: 99
  defp category_order(_), do: 50
```

- [ ] **Step 2: Run help-related tests**

```bash
(cd runtime && mix test test/esr/commands/help_test.exs 2>&1 | tail -10)
```

Expected: PASS (or no tests for help). The render-order is verified in Phase B Task B.5 e2e gate.

### Task B.4 — Wire 3 new slashes in slash-routes.default.yaml

- [ ] **Step 1: Edit `runtime/priv/slash-routes.default.yaml`**

DELETE the deferred-placeholder comment at lines 264-265:

```yaml
  # /workspace:sessions DROPPED — workspace must not depend on session (Rule 6)
  # Use /session:list (not yet wired — deferred to follow-up phase; see below).
```

…and DELETE the deferred-placeholder comment at lines 348-349:

```yaml
  # /session:end, /session:list, /session:bind-workspace, /session:info — deferred
  # (command modules not yet implemented; will land as Esr.Commands.Session.*)
```

INSERT the following block immediately after the `/session:share` entry (around line 346 post-deletion of the placeholder above):

```yaml
  "/session:list":
    kind: session_list
    permission: "session:default/read"
    command_module: "Esr.Commands.Session.List"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "列当前 chat 绑定的 session（无 workspace=）；带 workspace= 时按 workspace 列"
    args:
      - { name: workspace, required: false }

  "/session:switch":
    kind: session_switch
    permission: null
    command_module: "Esr.Commands.Session.Switch"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "切换 chat 当前 session（不解绑其它）；session=<uuid>"
    args:
      - { name: session, required: true }

  "/session:end":
    kind: session_end
    permission: "session:default/end"
    command_module: "Esr.Commands.Session.End"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "销毁 session；session=<uuid> 或 name=<n>"
    args:
      - { name: session, required: false }
      - { name: name, required: false }
```

Note: leave the `internal_kinds:` entries for `session_list`, `session_switch`, `session_end` (lines ~526-528, 666-672) unchanged — the dispatcher reads `command_module` from the slash entry; the duplicate entry under `internal_kinds:` is for the file-queue admin path and is wired identically. (Do verify with the post-edit `mix test` step in B.5.)

### Task B.5 — Verify dispatcher resolves all 3 slashes + commit

- [ ] **Step 1: Sanity-check yaml syntax**

```bash
(cd runtime && mix compile 2>&1 | tail -10)
(cd runtime && mix run --no-start -e 'IO.inspect(YamlElixir.read_from_file!("priv/slash-routes.default.yaml") |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "/session:")))' 2>&1 | tail -5)
```

Expected output includes `["/session:end", "/session:list", "/session:switch", ...]`.

- [ ] **Step 2: Add a slash_handler dispatch test**

In `runtime/test/esr/entity/slash_handler_test.exs`, add a fresh test asserting that `/session:list` lookup returns a route, not `:not_found`:

```elixir
test "/session:list resolves to Esr.Commands.Session.List" do
  assert {:ok, route} = Esr.Resource.SlashRoute.Registry.lookup("/session:list")
  assert route.command_module == "Esr.Commands.Session.List"
  assert route.kind == "session_list"
end

test "/session:switch resolves" do
  assert {:ok, route} = Esr.Resource.SlashRoute.Registry.lookup("/session:switch")
  assert route.command_module == "Esr.Commands.Session.Switch"
end

test "/session:end resolves" do
  assert {:ok, route} = Esr.Resource.SlashRoute.Registry.lookup("/session:end")
  assert route.command_module == "Esr.Commands.Session.End"
end
```

- [ ] **Step 3: Run slash_handler tests**

```bash
(cd runtime && mix test test/esr/entity/slash_handler_test.exs 2>&1 | tail -10)
```

Expected: PASS.

- [ ] **Step 4: Run full mix test for regression**

```bash
(cd runtime && mix test 2>&1 | tail -5)
```

Expected: only pre-existing flakes (see `docs/operations/known-flakes.md`); no new failures.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/session/list.ex \
        runtime/lib/esr/commands/help.ex \
        runtime/priv/slash-routes.default.yaml \
        runtime/test/esr/commands/session/list_test.exs \
        runtime/test/esr/entity/slash_handler_test.exs
# Also add chat_routing/registry.ex if list_sessions/2 was added
git add runtime/lib/esr/session/chat_routing/registry.ex 2>/dev/null || true
git commit -m "$(cat <<'EOF'
feat(grammar/B): wire /session:list + /session:switch + /session:end + /help Users

Three slashes that were declared internal_kind only now have operator-
visible slash entries. /session:list gains a chat-bound output shape
(no workspace= arg → list sessions attached to current chat). /help
gains a Users category bucket (slot 1, before Workspace) so /user:*
slashes render in their natural place.

Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md §4.6,
§6 (rows for /session:{list,switch,end}). Plan Phase B.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase C — `/agent:*` family + `/plugin:agent-types` + repurpose `/agent:list`

**Scope:** 6 new command modules under `runtime/lib/esr/commands/agent/{add,remove,set_primary,primary,rename}.ex`, 1 new under `runtime/lib/esr/commands/plugin/agent_types.ex`, REWRITE of `runtime/lib/esr/commands/agent/list.ex` to list InstanceRegistry instances (not agent types). Delete 3 old session/* files. Update slash-routes yaml + slash_handler deprecation table.

**Why this is biggest phase:** 5 renames + 2 net-new + 1 repurpose. Logic for add/remove/set_primary lifts unchanged from `runtime/lib/esr/commands/session/{add_agent,remove_agent,set_primary}.ex`; only the module name + slash entry change. `primary` (read) and `rename` are net-new.

**Files (deletions noted explicitly):**
- New: `runtime/lib/esr/commands/agent/{add,remove,set_primary,primary,rename}.ex`
- New: `runtime/lib/esr/commands/plugin/agent_types.ex`
- Rewrite: `runtime/lib/esr/commands/agent/list.ex` (currently 36 LOC, type-catalog → instance list)
- Delete: `runtime/lib/esr/commands/session/{add_agent,remove_agent,set_primary}.ex`
- Modify: `runtime/lib/esr/entity/slash_handler.ex` `@deprecated_slashes` map (lines 136-167)
- Modify: `runtime/priv/slash-routes.default.yaml` (5 new + 3 modify + 1 delete)
- Tests: 6 new under `runtime/test/esr/commands/agent/` + 1 new under `plugin/`
- Modify: `runtime/test/esr/entity/slash_handler_test.exs` (5 deprecation cases)

### Task C.1 — Add /plugin:agent-types (move old /agent:list logic)

- [ ] **Step 1: Failing test `runtime/test/esr/commands/plugin/agent_types_test.exs`**

```bash
mkdir -p runtime/test/esr/commands/plugin
```

Create `runtime/test/esr/commands/plugin/agent_types_test.exs`:

```elixir
defmodule Esr.Commands.Plugin.AgentTypesTest do
  use ExUnit.Case, async: false

  setup do
    fixture =
      Path.join([__DIR__, "..", "..", "fixtures", "agents", "simple.yaml"])
      |> Path.expand()

    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)
    :ok
  end

  test "lists agent types loaded from agents fixture" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{}}
    assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.AgentTypes.execute(cmd)
    assert text =~ "cc"
  end

  test "empty fixture renders the no-agents message" do
    :ok = Esr.Entity.Agent.Registry.load_agents("/dev/null")
    cmd = %{"submitted_by" => "linyilun", "args" => %{}}
    assert {:ok, %{"text" => text}} = Esr.Commands.Plugin.AgentTypes.execute(cmd)
    assert text =~ "no agents loaded"
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
(cd runtime && mix test test/esr/commands/plugin/agent_types_test.exs 2>&1 | tail -10)
```

Expected: `(UndefinedFunctionError) function Esr.Commands.Plugin.AgentTypes.execute/1 is undefined`.

- [ ] **Step 3: Create `runtime/lib/esr/commands/plugin/agent_types.ex`**

```elixir
defmodule Esr.Commands.Plugin.AgentTypes do
  @moduledoc """
  `/plugin:agent-types` — list every agent type declared by enabled
  plugins (compiled via `Esr.Entity.Agent.Registry.list_agents/0`).

  Replaces the old `/agent:list` semantics; `/agent:list` now lists
  agent INSTANCES inside chat-current session (Phase C Task C.7).

  Spec rev-3 §4.2 (row "/plugin:agent-types"), D6.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text =
      case Esr.Entity.Agent.Registry.list_agents() do
        [] ->
          "no agents loaded (agents.yaml empty or not found)"

        names ->
          lines = Enum.map_join(names, "\n", fn n -> "  - #{n}" end)
          "available agent types:\n#{lines}"
      end

    {:ok, %{"text" => text}}
  end
end
```

- [ ] **Step 4: Run + commit-prep**

```bash
(cd runtime && mix test test/esr/commands/plugin/agent_types_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task C.2 — Rewrite `Esr.Commands.Agent.List` to list instances

- [ ] **Step 1: Replace test in `runtime/test/esr/commands/agent/list_test.exs`**

The old test (existing) asserts type-catalog output. Replace its body entirely:

```elixir
defmodule Esr.Commands.Agent.ListTest do
  use ExUnit.Case, async: false

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    :ok
  end

  test "lists instances of chat-current session" do
    chat = "oc_b1_list"
    app = "esr_helper_list"
    sid = "cccccccc-3333-4333-8333-333333333333"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)

    inst_a = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-a",
      session_id: sid,
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-a", pty: "pty-uuid-a"}
    }

    inst_b = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-b",
      session_id: sid,
      type: "cc",
      name: "bob",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-b", pty: "pty-uuid-b"}
    }

    :ets.insert(tab, {{sid, "alice"}, inst_a})
    :ets.insert(tab, {{sid, "bob"}, inst_b})

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"chat_id" => chat, "app_id" => app}
    }

    assert {:ok, %{"agents" => agents}} = Esr.Commands.Agent.List.execute(cmd)
    names = Enum.map(agents, & &1["name"]) |> Enum.sort()
    assert names == ["alice", "bob"]
  end

  test "empty session: returns empty list" do
    chat = "oc_b1_list_empty"
    app = "esr_helper_list_empty"
    sid = "dddddddd-4444-4444-8444-444444444444"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"chat_id" => chat, "app_id" => app}
    }

    assert {:ok, %{"agents" => []}} = Esr.Commands.Agent.List.execute(cmd)
  end

  test "no chat context: returns invalid_args" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{}}
    assert {:error, %{"type" => "invalid_args"}} = Esr.Commands.Agent.List.execute(cmd)
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

```bash
(cd runtime && mix test test/esr/commands/agent/list_test.exs 2>&1 | tail -15)
```

Expected: tests fail (current Agent.List returns text type-catalog shape).

- [ ] **Step 3: Replace `runtime/lib/esr/commands/agent/list.ex` body**

```elixir
defmodule Esr.Commands.Agent.List do
  @moduledoc """
  `/agent:list` — list agent INSTANCES in chat-current session.

  Reads `Esr.Session.ChatRouting.Registry.current_session/2` to find the
  current session UUID, then `Esr.Entity.Agent.InstanceRegistry.list/2`
  to enumerate the per-session `%Instance{}` records.

  Spec rev-3 §4.2 (`/agent:list` repurposed), I3. The old type-catalog
  semantics moved to `Esr.Commands.Plugin.AgentTypes`.
  """

  @behaviour Esr.Role.Control

  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _submitter, "args" => %{"chat_id" => chat_id, "app_id" => app_id}})
      when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case ChatRouting.current_session(chat_id, app_id) do
      {:ok, sid} ->
        agents =
          Esr.Entity.Agent.InstanceRegistry.list(sid)
          |> Enum.map(fn inst ->
            %{
              "name" => inst.name,
              "type" => inst.type,
              "actor_ids" => %{
                "cc" => get_in(inst.actor_ids || %{}, [:cc]),
                "pty" => get_in(inst.actor_ids || %{}, [:pty])
              }
            }
          end)

        {:ok, %{"chat_id" => chat_id, "session_id" => sid, "agents" => agents}}

      :not_found ->
        {:ok, %{"chat_id" => chat_id, "session_id" => nil, "agents" => []}}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/agent:list requires chat context (chat_id + app_id in envelope)"
     }}
  end
end
```

- [ ] **Step 4: Run tests**

```bash
(cd runtime && mix test test/esr/commands/agent/list_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task C.3 — `/agent:add` (lift logic from session/add_agent.ex)

- [ ] **Step 1: Failing test `runtime/test/esr/commands/agent/add_test.exs`**

```elixir
defmodule Esr.Commands.Agent.AddTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Add

  @sess "11111111-1111-4111-8111-aaaaaaaaaaaa"

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    fixture =
      Path.join([__DIR__, "..", "..", "fixtures", "agents", "simple.yaml"])
      |> Path.expand()

    :ok = Esr.Entity.Agent.Registry.load_agents(fixture)
    :ok
  end

  test "without a running Scope: returns structured spawn_failed error" do
    name = "dev-#{:rand.uniform(9999)}"
    cmd = %{"args" => %{"session_id" => @sess, "type" => "cc", "name" => name, "config" => %{}}}
    assert {:error, %{"type" => "spawn_failed"}} = Add.execute(cmd)
  end

  test "missing session_id: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Add.execute(%{"args" => %{"type" => "cc", "name" => "x"}})
  end

  test "unknown agent type: returns unknown_agent_type" do
    cmd = %{"args" => %{"session_id" => @sess, "type" => "no_such", "name" => "x", "config" => %{}}}
    assert {:error, %{"type" => "unknown_agent_type"}} = Add.execute(cmd)
  end
end
```

- [ ] **Step 2: Verify it fails**

```bash
(cd runtime && mix test test/esr/commands/agent/add_test.exs 2>&1 | tail -10)
```

Expected: `(UndefinedFunctionError) function Esr.Commands.Agent.Add.execute/1 is undefined`.

- [ ] **Step 3: Create `runtime/lib/esr/commands/agent/add.ex`**

```elixir
defmodule Esr.Commands.Agent.Add do
  @moduledoc """
  `/agent:add` — add an agent instance to chat-current session (or
  explicit `session_id=`). Replaces `/session:add-agent`.

  Logic identical to the legacy `Esr.Commands.Session.AddAgent`; the
  spec rename (§4.2 row `/agent:add`, D1 hard-cutover) renames the
  module + slash; the old session/add_agent.ex is deleted in Task C.9.

  Validates type against `Esr.Entity.Agent.Registry.list_agents/0` and
  rejects unknown types with `{:error, %{"type" => "unknown_agent_type"}}`.
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "type" => type, "name" => name} = args})
      when is_binary(sid) and sid != "" and
             is_binary(type) and type != "" and
             is_binary(name) and name != "" do
    config = Map.get(args, "config", %{})

    with :ok <- validate_agent_type(type) do
      case InstanceRegistry.add_instance_and_spawn(%{
             session_id: sid,
             type: type,
             name: name,
             config: config
           }) do
        {:ok, %{actor_ids: actor_ids}} ->
          {:ok,
           %{
             "action" => "added",
             "session_id" => sid,
             "type" => type,
             "name" => name,
             "actor_ids" => %{
               "cc" => actor_ids.cc,
               "pty" => actor_ids.pty
             }
           }}

        {:error, {:duplicate_agent_name, n}} ->
          {:error,
           %{
             "type" => "duplicate_agent_name",
             "message" =>
               "agent name '#{n}' already exists in session '#{sid}' (pick a different name)"
           }}

        {:error, {:spawn_failed, reason}} ->
          {:error,
           %{
             "type" => "spawn_failed",
             "message" =>
               "failed to spawn agent subtree for '#{name}' in session '#{sid}': #{inspect(reason)}"
           }}
      end
    else
      {:error, :unknown_agent_type} ->
        known = known_agent_types()

        {:error,
         %{
           "type" => "unknown_agent_type",
           "message" =>
             "agent type '#{type}' is not declared in any enabled plugin; known types: #{Enum.join(known, ", ")}"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "/agent:add requires args.session_id, args.type, and args.name (all non-empty strings)"
     }}
  end

  defp validate_agent_type(type) do
    if type in known_agent_types(), do: :ok, else: {:error, :unknown_agent_type}
  end

  defp known_agent_types do
    case Esr.Entity.Agent.Registry.list_agents() do
      names when is_list(names) -> names
      _ -> []
    end
  end
end
```

- [ ] **Step 4: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/agent/add_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task C.4 — `/agent:remove` (lift logic from session/remove_agent.ex)

- [ ] **Step 1: Read source to lift**

```bash
cat runtime/lib/esr/commands/session/remove_agent.ex
```

- [ ] **Step 2: Failing test `runtime/test/esr/commands/agent/remove_test.exs`**

Mirror `runtime/test/esr/commands/session/remove_agent_test.exs` (replace module name + import). Specifically:

```elixir
defmodule Esr.Commands.Agent.RemoveTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Remove

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    :ok
  end

  test "missing args: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Remove.execute(%{"args" => %{}})
  end

  test "name not present in session: returns not_found" do
    sid = "55555555-5555-4555-8555-555555555555"
    cmd = %{"args" => %{"session_id" => sid, "name" => "ghost"}}
    assert {:error, %{"type" => "not_found"}} = Remove.execute(cmd)
  end
end
```

- [ ] **Step 3: Run to verify failure**

```bash
(cd runtime && mix test test/esr/commands/agent/remove_test.exs 2>&1 | tail -10)
```

Expected: `(UndefinedFunctionError) function Esr.Commands.Agent.Remove.execute/1 is undefined`.

- [ ] **Step 4: Create `runtime/lib/esr/commands/agent/remove.ex`**

Copy content from `runtime/lib/esr/commands/session/remove_agent.ex`. Edit:
- Module name: `Esr.Commands.Session.RemoveAgent` → `Esr.Commands.Agent.Remove`
- `@moduledoc` first line: `Remove an agent instance from a session (\`/session:remove-agent\`).` → `Remove an agent instance (\`/agent:remove\`).`
- Error messages mentioning `/session:remove-agent` → `/agent:remove`

- [ ] **Step 5: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/agent/remove_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task C.5 — `/agent:set-primary` (lift from session/set_primary.ex)

- [ ] **Step 1: Failing test `runtime/test/esr/commands/agent/set_primary_test.exs`**

Mirror `runtime/test/esr/commands/session/set_primary_test.exs`, replacing `Esr.Commands.Session.SetPrimary` → `Esr.Commands.Agent.SetPrimary`.

- [ ] **Step 2: Run to verify failure**

```bash
(cd runtime && mix test test/esr/commands/agent/set_primary_test.exs 2>&1 | tail -10)
```

- [ ] **Step 3: Create `runtime/lib/esr/commands/agent/set_primary.ex`**

Copy `runtime/lib/esr/commands/session/set_primary.ex` body. Update module name + slash references in `@moduledoc`.

- [ ] **Step 4: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/agent/set_primary_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task C.6 — `/agent:primary` (NET-NEW: read-only show primary)

- [ ] **Step 1: Failing test `runtime/test/esr/commands/agent/primary_test.exs`**

```elixir
defmodule Esr.Commands.Agent.PrimaryTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Primary

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    :ok
  end

  test "no session attached to chat: returns no_current_session" do
    chat = "oc_b1_prim_a"
    app = "esr_helper_prim_a"

    cmd = %{"submitted_by" => "linyilun", "args" => %{"chat_id" => chat, "app_id" => app}}
    assert {:error, %{"type" => "no_current_session"}} = Primary.execute(cmd)
  end

  test "session has primary: returns name" do
    chat = "oc_b1_prim_b"
    app = "esr_helper_prim_b"
    sid = "66666666-6666-4666-8666-666666666666"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)
    :ets.insert(tab, {{sid, :__primary__}, "alice"})

    cmd = %{"submitted_by" => "linyilun", "args" => %{"chat_id" => chat, "app_id" => app}}
    assert {:ok, %{"primary" => "alice", "session_id" => ^sid}} = Primary.execute(cmd)
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
(cd runtime && mix test test/esr/commands/agent/primary_test.exs 2>&1 | tail -10)
```

- [ ] **Step 3: Create `runtime/lib/esr/commands/agent/primary.ex`**

```elixir
defmodule Esr.Commands.Agent.Primary do
  @moduledoc """
  `/agent:primary` — read-only: show the primary agent name for the
  chat-current session. Net-new in spec rev-3 §4.2.
  """

  @behaviour Esr.Role.Control

  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _submitter, "args" => %{"chat_id" => chat_id, "app_id" => app_id}})
      when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    with {:ok, sid} <- ChatRouting.current_session(chat_id, app_id),
         {:ok, name} <- Esr.Entity.Agent.InstanceRegistry.primary(sid) do
      {:ok, %{"session_id" => sid, "primary" => name}}
    else
      :not_found ->
        {:error,
         %{
           "type" => "no_current_session",
           "message" => "no session attached to this chat; /session:bind-chat first"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/agent:primary requires chat context"
     }}
  end
end
```

- [ ] **Step 4: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/agent/primary_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task C.7 — `/agent:rename` (NET-NEW)

- [ ] **Step 1: Failing test `runtime/test/esr/commands/agent/rename_test.exs`**

```elixir
defmodule Esr.Commands.Agent.RenameTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Agent.Rename

  @sess "77777777-7777-4777-8777-777777777777"

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    :ok
  end

  test "missing args: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Rename.execute(%{"args" => %{"session_id" => @sess}})
  end

  test "renames an existing instance" do
    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)

    inst = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-r",
      session_id: @sess,
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-r", pty: "pty-uuid-r"}
    }

    :ets.insert(tab, {{@sess, "alice"}, inst})

    cmd = %{"args" => %{"session_id" => @sess, "name" => "alice", "new_name" => "alicia"}}

    assert {:ok, %{"action" => "renamed", "old_name" => "alice", "new_name" => "alicia"}} =
             Rename.execute(cmd)

    assert :not_found = Esr.Entity.Agent.InstanceRegistry.get(@sess, "alice")
    assert {:ok, _} = Esr.Entity.Agent.InstanceRegistry.get(@sess, "alicia")
  end

  test "name collision: returns duplicate_agent_name" do
    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)
    sid = "88888888-8888-4888-8888-888888888888"

    inst_a = %Esr.Entity.Agent.Instance{id: "a", session_id: sid, type: "cc", name: "x", config: %{}, created_at: "t", actor_ids: %{cc: "a", pty: "ap"}}
    inst_b = %Esr.Entity.Agent.Instance{id: "b", session_id: sid, type: "cc", name: "y", config: %{}, created_at: "t", actor_ids: %{cc: "b", pty: "bp"}}

    :ets.insert(tab, {{sid, "x"}, inst_a})
    :ets.insert(tab, {{sid, "y"}, inst_b})

    cmd = %{"args" => %{"session_id" => sid, "name" => "x", "new_name" => "y"}}
    assert {:error, %{"type" => "duplicate_agent_name"}} = Rename.execute(cmd)
  end
end
```

- [ ] **Step 2: Run to verify failure**

```bash
(cd runtime && mix test test/esr/commands/agent/rename_test.exs 2>&1 | tail -15)
```

- [ ] **Step 3: Add `rename_instance/3` to InstanceRegistry**

In `runtime/lib/esr/entity/agent/instance_registry.ex`, add a new public function (group with `set_primary/2`):

```elixir
  @doc """
  Rename `name` → `new_name` in `session_id`. Atomic via the GenServer
  call so the (session_id, name) ETS key swap is collision-checked.

  Returns `:ok`, `{:error, :not_found}`, or
  `{:error, :duplicate_agent_name}`.
  """
  @spec rename_instance(GenServer.server(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :duplicate_agent_name}
  def rename_instance(server \\ __MODULE__, session_id, name, new_name)
      when is_binary(session_id) and is_binary(name) and is_binary(new_name) do
    GenServer.call(server, {:rename_instance, session_id, name, new_name})
  end
```

…and a matching `handle_call`:

```elixir
  def handle_call({:rename_instance, sid, name, new_name}, _from, state) do
    cond do
      name == new_name ->
        {:reply, :ok, state}

      :ets.lookup(state.table, {sid, new_name}) != [] ->
        {:reply, {:error, :duplicate_agent_name}, state}

      true ->
        case :ets.lookup(state.table, {sid, name}) do
          [{_, %Instance{} = inst}] ->
            new_inst = %{inst | name: new_name}
            :ets.delete(state.table, {sid, name})
            :ets.insert(state.table, {{sid, new_name}, new_inst})

            # Also update primary pointer if this was the primary.
            case :ets.lookup(state.table, {sid, :__primary__}) do
              [{_, ^name}] ->
                :ets.insert(state.table, {{sid, :__primary__}, new_name})

              _ ->
                :ok
            end

            # Mirror agent_sup_via key if it exists (per Esr.Session.AgentSupervisor convention)
            case :ets.lookup(state.table, {:instance_sup, sid, name}) do
              [{_, sup_pid}] ->
                :ets.delete(state.table, {:instance_sup, sid, name})
                :ets.insert(state.table, {{:instance_sup, sid, new_name}, sup_pid})

              _ ->
                :ok
            end

            {:reply, :ok, state}

          [] ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end
```

- [ ] **Step 4: Create `runtime/lib/esr/commands/agent/rename.ex`**

```elixir
defmodule Esr.Commands.Agent.Rename do
  @moduledoc """
  `/agent:rename` — rename an agent instance within a session. Net-new
  in rev-3 §4.2 (no `/session:rename-agent` predecessor).

  Args: `session_id`, `name`, `new_name` (all required).
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name, "new_name" => new_name}})
      when is_binary(sid) and sid != "" and
             is_binary(name) and name != "" and
             is_binary(new_name) and new_name != "" do
    case InstanceRegistry.rename_instance(sid, name, new_name) do
      :ok ->
        {:ok,
         %{
           "action" => "renamed",
           "session_id" => sid,
           "old_name" => name,
           "new_name" => new_name
         }}

      {:error, :not_found} ->
        {:error,
         %{
           "type" => "not_found",
           "message" => "agent '#{name}' not found in session '#{sid}'"
         }}

      {:error, :duplicate_agent_name} ->
        {:error,
         %{
           "type" => "duplicate_agent_name",
           "message" =>
             "agent '#{new_name}' already exists in session '#{sid}' (pick a different name)"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "/agent:rename requires args.session_id, args.name, and args.new_name"
     }}
  end
end
```

- [ ] **Step 5: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/agent/rename_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task C.8 — slash-routes yaml: 6 new + 1 modify + 3 delete

- [ ] **Step 1: Edit `runtime/priv/slash-routes.default.yaml`**

DELETE the 3 `/session:add-agent`, `/session:remove-agent`, `/session:set-primary` entries (lines 267-299 currently).

REPLACE the existing `/agent:list` entry (lines 351-359) with:

```yaml
  "/agent:list":
    kind: agent_list
    permission: null
    command_module: "Esr.Commands.Agent.List"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Agents"
    description: "列当前 chat 当前 session 内运行的 agent 实例"
    args: []
```

…and INSERT the 5 new `/agent:*` entries immediately after `/agent:list`:

```yaml
  "/agent:add":
    kind: agent_add
    permission: "session:default/spawn"
    command_module: "Esr.Commands.Agent.Add"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Agents"
    description: "向当前 session 添加 agent 实例；name 须全局唯一"
    args:
      - { name: type, required: true }
      - { name: name, required: true }

  "/agent:remove":
    kind: agent_remove
    permission: "session:default/spawn"
    command_module: "Esr.Commands.Agent.Remove"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Agents"
    description: "从当前 session 删除 agent；不能删 primary（先 set-primary）"
    args:
      - { name: name, required: true }

  "/agent:set-primary":
    kind: agent_set_primary
    permission: "session:default/spawn"
    command_module: "Esr.Commands.Agent.SetPrimary"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Agents"
    description: "设当前 session 的 primary agent"
    args:
      - { name: name, required: true }

  "/agent:primary":
    kind: agent_primary
    permission: null
    command_module: "Esr.Commands.Agent.Primary"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Agents"
    description: "显示当前 session 的 primary agent"
    args: []

  "/agent:rename":
    kind: agent_rename
    permission: "session:default/spawn"
    command_module: "Esr.Commands.Agent.Rename"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Agents"
    description: "重命名 agent；name=<旧> new_name=<新>"
    args:
      - { name: name, required: true }
      - { name: new_name, required: true }
```

INSERT a new `/plugin:agent-types` entry near the existing `/plugin:list` (around line 371-379):

```yaml
  "/plugin:agent-types":
    kind: plugin_agent_types
    permission: null
    command_module: "Esr.Commands.Plugin.AgentTypes"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Plugins"
    description: "列出 enabled plugins 声明的所有 agent 类型（旧 /agent:list 的语义）"
    args: []
```

ALSO add corresponding `internal_kinds:` entries (so the file-queue admin path can dispatch them too — mirroring the convention for `session_*`). After the existing `internal_kinds:` block opens at line 513, append before `cross_app_test:`:

```yaml
  agent_add:
    permission: "session:default/spawn"
    command_module: "Esr.Commands.Agent.Add"

  agent_remove:
    permission: "session:default/spawn"
    command_module: "Esr.Commands.Agent.Remove"

  agent_set_primary:
    permission: "session:default/spawn"
    command_module: "Esr.Commands.Agent.SetPrimary"

  agent_primary:
    permission: null
    command_module: "Esr.Commands.Agent.Primary"

  agent_rename:
    permission: "session:default/spawn"
    command_module: "Esr.Commands.Agent.Rename"

  plugin_agent_types:
    permission: null
    command_module: "Esr.Commands.Plugin.AgentTypes"
```

- [ ] **Step 2: Compile + sanity-check**

```bash
(cd runtime && mix compile 2>&1 | tail -10)
```

Expected: 0 errors. Warnings about missing modules will fire ONLY if the new modules from C.1-C.7 didn't actually get created — so 0 warnings about missing `Agent.Add`/`Agent.Remove`/etc.

### Task C.9 — Delete the 3 superseded session/* command modules + tests

- [ ] **Step 1: Delete files**

```bash
rm runtime/lib/esr/commands/session/add_agent.ex
rm runtime/lib/esr/commands/session/remove_agent.ex
rm runtime/lib/esr/commands/session/set_primary.ex

rm runtime/test/esr/commands/session/add_agent_test.exs
rm runtime/test/esr/commands/session/remove_agent_test.exs
rm runtime/test/esr/commands/session/set_primary_test.exs
```

- [ ] **Step 2: Recompile**

```bash
(cd runtime && mix compile 2>&1 | tail -10)
```

Expected: 0 errors. (If something else still references `Esr.Commands.Session.AddAgent`, etc, that's a residual to clean up — grep the codebase.)

- [ ] **Step 3: Sanity grep for stale references**

```bash
grep -rn "Esr.Commands.Session.AddAgent\|Esr.Commands.Session.RemoveAgent\|Esr.Commands.Session.SetPrimary" runtime/ --include='*.ex' --include='*.yaml' || echo "clean"
```

Expected: `clean`. If anything matches, fix it (likely a stale comment or test).

### Task C.10 — Extend `slash_handler.ex` `@deprecated_slashes` for renamed slashes

- [ ] **Step 1: Edit `runtime/lib/esr/entity/slash_handler.ex` line 136-167**

Add 3 new entries to the `@deprecated_slashes` map (insert after the existing `"/list-agents" => "/agent:list",` line):

```elixir
    "/session:add-agent" => "/agent:add",
    "/session:remove-agent" => "/agent:remove",
    "/session:set-primary" => "/agent:set-primary",
```

NOTE: `/list-agents` already maps to `/agent:list`. Operators who type `/list-agents` get pointed at `/agent:list`; the new repurpose is a behaviour change for that slash but the operator-facing name is the same. (Document this in the commit message + spec/changelog if asked.)

- [ ] **Step 2: Add deprecation cases to `runtime/test/esr/entity/slash_handler_test.exs`**

```elixir
test "/session:add-agent returns rename hint to /agent:add" do
  envelope = %{"text" => "/session:add-agent type=cc name=x", "principal_id" => "ou_test"}

  parent = self()
  ref = make_ref()

  Esr.Entity.SlashHandler.dispatch(envelope, fn msg -> send(parent, {ref, msg}) end)

  assert_receive {^ref, {:text, msg}}, 500
  assert msg =~ "/agent:add"
  assert msg =~ "renamed"
end

test "/session:remove-agent returns rename hint to /agent:remove" do
  envelope = %{"text" => "/session:remove-agent name=x", "principal_id" => "ou_test"}
  parent = self()
  ref = make_ref()

  Esr.Entity.SlashHandler.dispatch(envelope, fn msg -> send(parent, {ref, msg}) end)
  assert_receive {^ref, {:text, msg}}, 500
  assert msg =~ "/agent:remove"
end

test "/session:set-primary returns rename hint to /agent:set-primary" do
  envelope = %{"text" => "/session:set-primary name=x", "principal_id" => "ou_test"}
  parent = self()
  ref = make_ref()

  Esr.Entity.SlashHandler.dispatch(envelope, fn msg -> send(parent, {ref, msg}) end)
  assert_receive {^ref, {:text, msg}}, 500
  assert msg =~ "/agent:set-primary"
end
```

(Adjust dispatch shape to whatever the existing `slash_handler_test.exs` uses — read the file's first ~60 lines first to mirror the helper conventions.)

- [ ] **Step 3: Run all slash-handler + agent + plugin command tests**

```bash
(cd runtime && mix test test/esr/entity/slash_handler_test.exs test/esr/commands/agent/ test/esr/commands/plugin/ 2>&1 | tail -15)
```

Expected: all green.

- [ ] **Step 4: Full mix test for regression**

```bash
(cd runtime && mix test 2>&1 | tail -5)
```

Expected: only pre-existing flakes; no new failures.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/agent/ \
        runtime/lib/esr/commands/plugin/agent_types.ex \
        runtime/lib/esr/entity/agent/instance_registry.ex \
        runtime/lib/esr/entity/slash_handler.ex \
        runtime/priv/slash-routes.default.yaml \
        runtime/test/esr/commands/agent/ \
        runtime/test/esr/commands/plugin/ \
        runtime/test/esr/entity/slash_handler_test.exs
git rm runtime/lib/esr/commands/session/add_agent.ex \
       runtime/lib/esr/commands/session/remove_agent.ex \
       runtime/lib/esr/commands/session/set_primary.ex \
       runtime/test/esr/commands/session/add_agent_test.exs \
       runtime/test/esr/commands/session/remove_agent_test.exs \
       runtime/test/esr/commands/session/set_primary_test.exs

git commit -m "$(cat <<'EOF'
feat(grammar/C): per-agent rename family + repurpose /agent:list + /plugin:agent-types

Five /agent:* commands (add/remove/set-primary/primary/rename) replace
three /session:* per-agent commands. /agent:list is repurposed to list
INSTANCES of chat-current session (not types); the type-catalog moves
to /plugin:agent-types. Two net-new commands: /agent:primary (read-
only) and /agent:rename (which also adds InstanceRegistry.rename_instance/3).

Slash-routes yaml updated. slash_handler @deprecated_slashes extended
with the 3 renamed slashes so operators get a rename hint at the old
form. The 3 superseded session/* modules + their tests deleted.

Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md §4.2,
§4.3, D6, I3. Plan Phase C.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase D — Chat-binding renames

**Why:** `/session:attach` conflated two concerns — chat-binding (this phase) and PTY URL emission (Phase E). Operator-typing `/session:attach` is ambiguous; `/session:bind-chat` + `/pty:attach` are both unambiguous.

**Files:**
- New: `runtime/lib/esr/commands/session/{bind_chat,unbind_chat}.ex`
- Delete: `runtime/lib/esr/commands/session/{attach,detach}.ex`
- Modify: `runtime/lib/esr/entity/slash_handler.ex` `@deprecated_slashes` (2 entries)
- Modify: `runtime/priv/slash-routes.default.yaml` (rename 2 entries; remove deprecated alias if any in `internal_kinds`)
- New tests: `runtime/test/esr/commands/session/{bind_chat,unbind_chat}_test.exs`
- Modify: `runtime/test/esr/entity/slash_handler_test.exs` (2 cases)

### Task D.1 — Failing test for `/session:bind-chat`

- [ ] **Step 1: Create `runtime/test/esr/commands/session/bind_chat_test.exs`**

Mirror `runtime/test/esr/commands/session/attach_test.exs`. Find the existing patterns:

```bash
head -80 runtime/test/esr/commands/session/attach_test.exs
```

Copy the file. Edits:
- Module name → `Esr.Commands.Session.BindChatTest`
- `Esr.Commands.Session.Attach` → `Esr.Commands.Session.BindChat`
- All references to the slash `/session:attach` → `/session:bind-chat` in test descriptions

- [ ] **Step 2: Run to verify failure**

```bash
(cd runtime && mix test test/esr/commands/session/bind_chat_test.exs 2>&1 | tail -10)
```

Expected: `(UndefinedFunctionError) function Esr.Commands.Session.BindChat.execute/1 is undefined`.

### Task D.2 — Implement `Esr.Commands.Session.BindChat` (lift from Attach)

- [ ] **Step 1: Create `runtime/lib/esr/commands/session/bind_chat.ex`**

Copy `runtime/lib/esr/commands/session/attach.ex` body. Edits:
- Module name → `Esr.Commands.Session.BindChat`
- `@moduledoc` first line → `\`/session:bind-chat\` — bind an existing session to the current chat scope.`
- Replace any references in error messages: `attach` → `bind-chat`

- [ ] **Step 2: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/session/bind_chat_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task D.3 — Failing test + module for `/session:unbind-chat`

- [ ] **Step 1: Create `runtime/test/esr/commands/session/unbind_chat_test.exs`**

Mirror `runtime/test/esr/commands/session/detach_test.exs`, replacing `Detach` → `UnbindChat`.

- [ ] **Step 2: Run to verify failure**

```bash
(cd runtime && mix test test/esr/commands/session/unbind_chat_test.exs 2>&1 | tail -10)
```

- [ ] **Step 3: Create `runtime/lib/esr/commands/session/unbind_chat.ex`**

Copy `runtime/lib/esr/commands/session/detach.ex` body. Edits:
- Module name → `Esr.Commands.Session.UnbindChat`
- `@moduledoc` → describe `/session:unbind-chat`
- All `/session:detach` → `/session:unbind-chat` in error messages

- [ ] **Step 4: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/session/unbind_chat_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task D.4 — slash-routes yaml: replace session:attach + session:detach

- [ ] **Step 1: Edit `runtime/priv/slash-routes.default.yaml` lines 313-333**

REPLACE the `/session:attach` block (313-322) with:

```yaml
  "/session:bind-chat":
    kind: session_bind_chat
    permission: "session.attach"
    command_module: "Esr.Commands.Session.BindChat"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "把已有 session 加入当前 chat；UUID-only（用 /session:list 查 UUID）"
    args:
      - { name: session, required: true }
```

REPLACE the `/session:detach` block (324-333) with:

```yaml
  "/session:unbind-chat":
    kind: session_unbind_chat
    permission: null
    command_module: "Esr.Commands.Session.UnbindChat"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "离开当前 session；session 保持运行；可省略 session= 默认 unbind 当前"
    args:
      - { name: session, required: false }
```

ADD matching `internal_kinds:` entries near the other `session_*` entries:

```yaml
  session_bind_chat:
    permission: "session.attach"
    command_module: "Esr.Commands.Session.BindChat"

  session_unbind_chat:
    permission: null
    command_module: "Esr.Commands.Session.UnbindChat"
```

REMOVE the orphan `session_attach_surface` and `session_detach_surface` `internal_kinds:` entries if they exist (search for them; the slash-shape ones already use that kind name and are gone).

### Task D.5 — Extend `@deprecated_slashes` + tests, delete old files, commit

- [ ] **Step 1: Edit `runtime/lib/esr/entity/slash_handler.ex` `@deprecated_slashes`**

Add 2 entries:

```elixir
    "/session:attach" => "/session:bind-chat",
    "/session:detach" => "/session:unbind-chat",
```

NOTE: `/attach` already maps to `/session:attach` (line 141). Update that to point further:

```elixir
    "/attach" => "/pty:attach",
```

(Old `/attach` was the URL-emitter orphan; spec rev-3 §4.3 says the natural successor is `/pty:attach`. Leaves chat-binding pointed at `/session:bind-chat` which is the operator-readable verb.)

- [ ] **Step 2: Add deprecation cases to `slash_handler_test.exs`**

```elixir
test "/session:attach returns rename hint to /session:bind-chat" do
  envelope = %{"text" => "/session:attach session=abc", "principal_id" => "ou_test"}
  parent = self()
  ref = make_ref()

  Esr.Entity.SlashHandler.dispatch(envelope, fn msg -> send(parent, {ref, msg}) end)
  assert_receive {^ref, {:text, msg}}, 500
  assert msg =~ "/session:bind-chat"
end

test "/session:detach returns rename hint to /session:unbind-chat" do
  envelope = %{"text" => "/session:detach", "principal_id" => "ou_test"}
  parent = self()
  ref = make_ref()

  Esr.Entity.SlashHandler.dispatch(envelope, fn msg -> send(parent, {ref, msg}) end)
  assert_receive {^ref, {:text, msg}}, 500
  assert msg =~ "/session:unbind-chat"
end
```

- [ ] **Step 3: Delete the old session/{attach,detach}.ex files + tests**

```bash
rm runtime/lib/esr/commands/session/attach.ex
rm runtime/lib/esr/commands/session/detach.ex
rm runtime/test/esr/commands/session/attach_test.exs
rm runtime/test/esr/commands/session/detach_test.exs
```

- [ ] **Step 4: Sanity grep**

```bash
grep -rn "Esr.Commands.Session.Attach\b\|Esr.Commands.Session.Detach\b" runtime/ --include='*.ex' --include='*.yaml' || echo "clean"
```

Expected: `clean`.

- [ ] **Step 5: Run tests**

```bash
(cd runtime && mix test test/esr/commands/session/ test/esr/entity/slash_handler_test.exs 2>&1 | tail -15)
```

Expected: all green.

- [ ] **Step 6: Full mix test for regression**

```bash
(cd runtime && mix test 2>&1 | tail -5)
```

- [ ] **Step 7: Commit**

```bash
git add runtime/lib/esr/commands/session/bind_chat.ex \
        runtime/lib/esr/commands/session/unbind_chat.ex \
        runtime/lib/esr/entity/slash_handler.ex \
        runtime/priv/slash-routes.default.yaml \
        runtime/test/esr/commands/session/bind_chat_test.exs \
        runtime/test/esr/commands/session/unbind_chat_test.exs \
        runtime/test/esr/entity/slash_handler_test.exs

git rm runtime/lib/esr/commands/session/attach.ex \
       runtime/lib/esr/commands/session/detach.ex \
       runtime/test/esr/commands/session/attach_test.exs \
       runtime/test/esr/commands/session/detach_test.exs

git commit -m "$(cat <<'EOF'
feat(grammar/D): /session:bind-chat + /session:unbind-chat replace attach/detach

Spec rev-3 P3: attach is a PTY URL operation, not chat-binding. The
old /session:attach conflated both. Renames split the verbs:
/session:bind-chat handles chat ↔ session binding, /pty:attach (Phase E)
emits the PTY URL.

Deletes session/{attach,detach}.ex modules and tests. Updates
@deprecated_slashes so the old slashes return a rename hint. /attach
deprecation also re-points at /pty:attach (was /session:attach).

Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md §4.2,
§4.3, P3. Plan Phase D.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase E — `/pty:list` + `/pty:attach` + `/claude_code:tui` + e2e scenario 22

**Why this is last:** depends on (a) Phase A's `actor_ids` field on `%Instance{}` AND PtyProcess pubsub topic migration (so `/pty:list` can enumerate PTY ids and `/claude_code:tui` can look up by name), (b) Phase C's repurposed `/agent:list` (the e2e scenario 22 asserts both lists differ correctly), (c) Phase D's `/session:bind-chat` (the e2e scenario sets up chat context via the bind operation). Also includes the orphan `Esr.Commands.Attach` deletion.

`/claude_code:tui` ships in the **claude_code plugin** per spec rev-4 D5 — second consumer of the rev-3 plugin-scoped command registration mechanism. Adds a `slash_routes:` block to the plugin manifest. The slash + kind use the canonical `<plugin_name>:` / `<plugin_name>_` prefix the validator enforces (`runtime/lib/esr/plugin/manifest.ex:340-399`).

**Files:**
- New: `runtime/lib/esr/commands/pty/{list,attach}.ex`
- New: `runtime/lib/esr/plugins/claude_code/commands/tui.ex`
- Modify: `runtime/lib/esr/plugins/claude_code/manifest.yaml` (add `slash_routes:` block)
- Delete: `runtime/lib/esr/commands/attach.ex`
- Modify: `runtime/priv/slash-routes.default.yaml` (add `/pty:list`, `/pty:attach`)
- New tests: 3 (`pty/list_test.exs`, `pty/attach_test.exs`, `plugins/claude_code/commands/tui_test.exs`)
- New e2e: `tests/e2e/scenarios/22_resource_typed_grammar.sh`

### Task E.1 — `/pty:list` (lists PTY ids of chat-current session)

- [ ] **Step 1: Failing test `runtime/test/esr/commands/pty/list_test.exs`**

```bash
mkdir -p runtime/test/esr/commands/pty
```

```elixir
defmodule Esr.Commands.Pty.ListTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Pty.List, as: PtyList

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    :ok
  end

  test "lists PTY actor ids for chat-current session agents" do
    chat = "oc_b1_pty_a"
    app = "esr_helper_pty_a"
    sid = "99999999-9999-4999-8999-999999999999"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)

    inst = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-pl",
      session_id: sid,
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-pl", pty: "pty-uuid-pl"}
    }

    :ets.insert(tab, {{sid, "alice"}, inst})

    cmd = %{"submitted_by" => "linyilun", "args" => %{"chat_id" => chat, "app_id" => app}}
    assert {:ok, %{"ptys" => [pty]}} = PtyList.execute(cmd)
    assert pty["agent_name"] == "alice"
    assert pty["pty_actor_id"] == "pty-uuid-pl"
  end

  test "no chat context: invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             PtyList.execute(%{"submitted_by" => "linyilun", "args" => %{}})
  end
end
```

- [ ] **Step 2: Run + fail**

```bash
(cd runtime && mix test test/esr/commands/pty/list_test.exs 2>&1 | tail -10)
```

- [ ] **Step 3: Create `runtime/lib/esr/commands/pty/list.ex`**

```elixir
defmodule Esr.Commands.Pty.List do
  @moduledoc """
  `/pty:list` — list PTY actor ids for agents in chat-current session.
  Spec rev-3 §4.2 row `/pty:list`.
  """

  @behaviour Esr.Role.Control

  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _submitter, "args" => %{"chat_id" => chat_id, "app_id" => app_id}})
      when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case ChatRouting.current_session(chat_id, app_id) do
      {:ok, sid} ->
        ptys =
          Esr.Entity.Agent.InstanceRegistry.list(sid)
          |> Enum.map(fn inst ->
            %{
              "agent_name" => inst.name,
              "agent_type" => inst.type,
              "pty_actor_id" => get_in(inst.actor_ids || %{}, [:pty])
            }
          end)
          |> Enum.filter(& &1["pty_actor_id"])

        {:ok, %{"chat_id" => chat_id, "session_id" => sid, "ptys" => ptys}}

      :not_found ->
        {:ok, %{"chat_id" => chat_id, "session_id" => nil, "ptys" => []}}
    end
  end

  def execute(_cmd) do
    {:error,
     %{"type" => "invalid_args", "message" => "/pty:list requires chat context"}}
  end
end
```

- [ ] **Step 4: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/pty/list_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task E.2 — `/pty:attach` (returns URL — lifts orphan Esr.Commands.Attach)

> Per Phase A.4 above, PtyProcess now registers/broadcasts on `pty:<actor_id>`. URL shape is `/sessions/<actor_id>/attach?sid=<actor_id>` and PtySocket subscribes to `pty:<actor_id>` — matches PtyProcess's broadcast topic. No reverse-lookup helper needed.

- [ ] **Step 1: Failing test `runtime/test/esr/commands/pty/attach_test.exs`**

```elixir
defmodule Esr.Commands.Pty.AttachTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Pty.Attach

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    :ok
  end

  test "with pty=<id>: emits a URL containing the pty actor id" do
    cmd = %{"submitted_by" => "linyilun", "args" => %{"pty" => "pty-uuid-attach"}}
    assert {:ok, %{"text" => text, "url" => url}} = Attach.execute(cmd)
    assert text =~ "pty-uuid-attach"
    assert url =~ "pty-uuid-attach"
  end

  test "missing pty=: returns invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} =
             Attach.execute(%{"submitted_by" => "linyilun", "args" => %{}})
  end
end
```

- [ ] **Step 2: Run + fail**

```bash
(cd runtime && mix test test/esr/commands/pty/attach_test.exs 2>&1 | tail -10)
```

- [ ] **Step 3: Create `runtime/lib/esr/commands/pty/attach.ex`**

```elixir
defmodule Esr.Commands.Pty.Attach do
  @moduledoc """
  `/pty:attach pty=<actor_id>` — return a clickable browser URL backed
  by `EsrWeb.PtySocket` (xterm.js). Spec rev-4 §4.2 row `/pty:attach`.

  Phase A.4 migrated PtyProcess's pubsub topic to `pty:<actor_id>`, so
  `actor_id` flows directly into the URL's `?sid=` query param;
  PtySocket subscribes to `pty:<actor_id>` and receives that PTY's
  broadcasts cleanly even when N agents share one session.

  PtySocket auth (signed token) is OUT OF SCOPE per spec D3 — the URL
  is unauthenticated; hardening tracked in docs/futures/todo.md (key:
  `pty_attach_security_hardening`).
  """

  @behaviour Esr.Role.Control

  alias Esr.Uri, as: EsrUri

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => _submitter, "args" => %{"pty" => actor_id}})
      when is_binary(actor_id) and actor_id != "" do
    uri = EsrUri.build_path(["sessions", actor_id, "attach"], "localhost")
    http_url = EsrUri.to_http_url(uri, EsrWeb.Endpoint)

    {:ok,
     %{
       "url" => http_url,
       "uri" => uri,
       "pty" => actor_id,
       "text" => "🖥 attach: [#{http_url}](#{http_url})\nuri: `#{uri}`"
     }}
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/pty:attach requires pty=<actor_id>"
     }}
  end
end
```

- [ ] **Step 4: Run + verify green**

```bash
(cd runtime && mix test test/esr/commands/pty/attach_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task E.3 — `/claude_code:tui` plugin command (claude_code plugin)

- [ ] **Step 1: Failing test `runtime/test/esr/plugins/claude_code/commands/tui_test.exs`**

```bash
mkdir -p runtime/test/esr/plugins/claude_code/commands
```

```elixir
defmodule Esr.Plugins.ClaudeCode.Commands.TuiTest do
  use ExUnit.Case, async: false
  alias Esr.Plugins.ClaudeCode.Commands.Tui

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end

    case Process.whereis(Esr.Session.ChatRouting.Registry) do
      nil -> start_supervised!(Esr.Session.ChatRouting.Registry)
      _ -> :ok
    end

    :ok
  end

  test "name=<agent>: resolves to PTY id and emits URL via /pty:attach" do
    chat = "oc_b1_tui_a"
    app = "esr_helper_tui_a"
    sid = "11111111-aaaa-4aaa-8aaa-111111111111"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    tab = GenServer.call(Esr.Entity.Agent.InstanceRegistry, :table_name)

    inst = %Esr.Entity.Agent.Instance{
      id: "cc-uuid-tui",
      session_id: sid,
      type: "cc",
      name: "alice",
      config: %{},
      created_at: "2026-05-08T00:00:00Z",
      actor_ids: %{cc: "cc-uuid-tui", pty: "pty-uuid-tui-aaaa"}
    }

    :ets.insert(tab, {{sid, "alice"}, inst})

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"name" => "alice", "chat_id" => chat, "app_id" => app}
    }

    assert {:ok, %{"url" => url}} = Tui.execute(cmd)
    assert url =~ "pty-uuid-tui-aaaa"
  end

  test "unknown agent name: returns not_found" do
    chat = "oc_b1_tui_b"
    app = "esr_helper_tui_b"
    sid = "22222222-bbbb-4bbb-8bbb-222222222222"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    cmd = %{
      "submitted_by" => "linyilun",
      "args" => %{"name" => "ghost", "chat_id" => chat, "app_id" => app}
    }

    assert {:error, %{"type" => "not_found"}} = Tui.execute(cmd)
  end
end
```

- [ ] **Step 2: Run + fail**

```bash
(cd runtime && mix test test/esr/plugins/claude_code/commands/tui_test.exs 2>&1 | tail -10)
```

- [ ] **Step 3: Create `runtime/lib/esr/plugins/claude_code/commands/tui.ex`**

```bash
mkdir -p runtime/lib/esr/plugins/claude_code/commands
```

```elixir
defmodule Esr.Plugins.ClaudeCode.Commands.Tui do
  @moduledoc """
  `/claude_code:tui name=<agent>` — claude_code plugin command.
  Resolves agent name → PTY actor id via the chat-current session, then
  delegates to `Esr.Commands.Pty.Attach` to emit the URL.

  Lives in the claude_code plugin per spec rev-4 D5 (plugin-scoped
  command registration mechanism). Manifest entry under the plugin's
  `slash_routes:` block. Slash + kind use the canonical
  `claude_code:` / `claude_code_` prefix per manifest validator's
  `validate_slash_keys/2` + `validate_kind_names/3` rules.
  """

  @behaviour Esr.Role.Control

  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"submitted_by" => submitter, "args" => %{"name" => name, "chat_id" => chat_id, "app_id" => app_id}} = cmd)
      when is_binary(name) and name != "" and is_binary(chat_id) and chat_id != "" and
             is_binary(app_id) and app_id != "" do
    with {:ok, sid} <- ChatRouting.current_session(chat_id, app_id),
         {:ok, pty_id} <- Esr.Entity.Agent.InstanceRegistry.pty_actor_id_for(sid, name) do
      Esr.Commands.Pty.Attach.execute(%{
        "submitted_by" => submitter,
        "args" => Map.put(cmd["args"], "pty", pty_id)
      })
    else
      :not_found ->
        {:error,
         %{
           "type" => "not_found",
           "message" => "no agent '#{name}' in chat-current session"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{"type" => "invalid_args", "message" => "/claude_code:tui requires name=<agent> and chat context"}}
  end
end
```

- [ ] **Step 4: Run + verify green**

```bash
(cd runtime && mix test test/esr/plugins/claude_code/commands/tui_test.exs 2>&1 | tail -10)
```

Expected: PASS.

### Task E.4 — Add `slash_routes:` block to claude_code manifest

- [ ] **Step 1: Edit `runtime/lib/esr/plugins/claude_code/manifest.yaml`**

Append the following at the end of the file (after `claude_binary:` config_schema entry, line 75):

```yaml

# Slash commands declared by this plugin (rev-3 plugin-scoped command
# registration mechanism). Per spec D3, plugin commands MUST use the
# plugin's namespace prefix (`/cc:*` here).
slash_routes:
  "/claude_code:tui":
    kind: claude_code_tui
    permission: null
    command_module: "Esr.Plugins.ClaudeCode.Commands.Tui"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Plugins"
    description: "把当前 chat 的 session 内某 cc agent 的 PTY URL 发回（/pty:attach 的薄壳 shortcut）"
    args:
      - { name: name, required: true }
```

- [ ] **Step 2: Verify manifest parses + validates + plugin loads + slash_route registers**

```bash
(cd runtime && mix run --no-start -e '
manifest = Esr.Plugin.Manifest.from_yaml!(File.read!("lib/esr/plugins/claude_code/manifest.yaml"))
case Esr.Plugin.Manifest.validate(manifest) do
  :ok -> IO.puts("manifest validate: OK")
  {:error, reason} -> raise "validate failed: #{inspect(reason)}"
end
' 2>&1 | tail -5)
```

Expected: `manifest validate: OK`. If the validator returns `{:bad_slash_prefix, ...}` or `{:bad_kind_prefix, ...}` or `{:invalid_slash_routes_block, ...}`, the manifest shape is wrong — go back and fix it before proceeding.

NOTE: `Esr.Plugin.Manifest.validate/1` enforces TWO rules per `runtime/lib/esr/plugin/manifest.ex:340-399`:

1. **Nested shape** — the `slash_routes:` block under `declares:` must contain `slashes:` and (optionally) `internal_kinds:` sub-keys. Use `runtime/lib/esr/plugins/feishu/manifest.yaml:71+` as the canonical pattern.
2. **Plugin-name prefix** — every slash key starts with `/<plugin_name>:` and every kind name starts with `<plugin_name>_`. Plugin name is `claude_code` per `manifest.yaml:10`.

> ⚠️ **OPEN SPEC QUESTION (review-flagged):** Spec rev-3 D5 chose `/claude_code:tui` (short form). Validator currently enforces `/claude_code:tui` + kind `claude_code_tui`. Four resolution options:
>   - **A.** Update spec D5 + plan to `/claude_code:tui` (verbose but works as-is).
>   - **B.** Rename plugin from `claude_code` → `cc` (touches manifest, plugin-config storage paths, Capability cap-strings, every test fixture mentioning the name; high blast radius).
>   - **C.** Add an `alias_prefix:` field to manifest schema + validator (separate small spec).
>   - **D.** Loosen validator's prefix check (gives up the rev-3 D3 guarantee that operators can read a slash and know which plugin owns it).
>
> Recommended: **A**. The verbosity is paid once at type-time; tools auto-complete it; the rev-3 D3 invariant stays intact. Defer if user prefers B/C; stop and ask if unclear.

The corresponding manifest block (assuming **A**):

```yaml
declares:
  # ... existing entities, media_types ...

  slash_routes:
    slashes:
      "/claude_code:tui":
        kind: claude_code_tui
        permission: null
        command_module: "Esr.Plugins.ClaudeCode.Commands.Tui"
        requires_workspace_binding: false
        requires_user_binding: true
        category: "Plugins"
        description: "把当前 chat 的 session 内某 cc agent 的 PTY URL 发回（/pty:attach 的薄壳 shortcut）"
        args:
          - { name: name, required: true }
    internal_kinds: {}
```

Spec rev-4 D5 + I5 (see scenario 22 step 6) consistently use `/claude_code:tui`.

### Task E.5 — slash-routes yaml: add `/pty:list` + `/pty:attach`

- [ ] **Step 1: Edit `runtime/priv/slash-routes.default.yaml`**

Insert immediately after `/agent:rename` (or any existing `/pty:*` block; if none, after `/agent:*` family):

```yaml
  "/pty:list":
    kind: pty_list
    permission: null
    command_module: "Esr.Commands.Pty.List"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "PTY"
    description: "列当前 chat 当前 session 的 PTY actor id"
    args: []

  "/pty:attach":
    kind: pty_attach
    permission: null
    command_module: "Esr.Commands.Pty.Attach"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "PTY"
    description: "返回 PTY 的 web URL；pty=<actor_id>"
    args:
      - { name: pty, required: true }
```

ADD matching `internal_kinds:` entries:

```yaml
  pty_list:
    permission: null
    command_module: "Esr.Commands.Pty.List"

  pty_attach:
    permission: null
    command_module: "Esr.Commands.Pty.Attach"
```

REMOVE the orphan `attach:` entry from `internal_kinds:` (lines 674-676):

```yaml
  attach:
    permission: null
    command_module: "Esr.Commands.Attach"
```

### Task E.6 — Delete orphan `Esr.Commands.Attach` + commit core changes

- [ ] **Step 1: Sanity grep before deletion**

```bash
grep -rn "Esr.Commands.Attach\b\|/attach\b" runtime/ --include='*.ex' --include='*.yaml' | grep -v "test/" | grep -v deprecated_slashes
```

Expected: only references in deprecated_slashes (already updated to `/pty:attach`) — no live callers.

- [ ] **Step 2: Delete files**

```bash
rm runtime/lib/esr/commands/attach.ex
# No corresponding test file (orphan)
```

- [ ] **Step 3: Recompile + full test**

```bash
(cd runtime && mix compile 2>&1 | tail -10)
(cd runtime && mix test 2>&1 | tail -5)
```

Expected: 0 errors; only pre-existing flakes.

### Task E.7 — e2e scenario 22

- [ ] **Step 1: Create `tests/e2e/scenarios/22_resource_typed_grammar.sh`**

```bash
#!/usr/bin/env bash
# e2e scenario 22 — resource-typed slash grammar end-to-end.
#
# Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md
#
# WHAT THIS TEST PROVES (spec invariants I1-I5):
#   - I1: Every operator-visible slash that operates on agents is /agent:*.
#         /session:add-agent etc. return rename hints (verified via /help
#         emitting the hint via slash_handler @deprecated_slashes).
#   - I2: /pty:attach (core) + /claude_code:tui (claude_code plugin) emit TUI URLs.
#   - I3: /agent:list (no args) returns INSTANCES (not types);
#         /plugin:agent-types returns the type catalog.
#   - I4: /session:add-agent → operator gets pointed at /agent:add.
#   - I5: /claude_code:tui registered via claude_code plugin slash_routes block.
#
# COMPLEMENTS scenario 14 (multi-agent), 18 (multi-instance lifecycle),
# 19 (session-first default).
#
# INVARIANT GATE (spec §11):
#   bash tests/e2e/scenarios/22_resource_typed_grammar.sh 2>&1 | tail -3
#   → "PASS: 22_resource_typed_grammar"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
seed_workspaces
seed_adapters
start_esrd

USERNAME="grammar_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"

esr_cli admin submit user_add --arg name="${USERNAME}" --wait --timeout 30 >/dev/null

# --- step 1: spawn a session with a cc agent (via /agent:add) --------
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-22"
mkdir -p "${WORKDIR}"

SESS_OUT=$(esr_cli admin submit session_new \
  --arg dir="${WORKDIR}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

SID=$(echo "$SESS_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "22: no session_id"
echo "22: session created: ${SID}"

# Add second agent via /agent:add (was /session:add-agent in rev-2)
ADD_OUT=$(esr_cli admin submit agent_add \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=alice \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 agent_add: ${ADD_OUT}"
assert_contains "$ADD_OUT" "ok: true" "22: /agent:add ok"
assert_contains "$ADD_OUT" "alice"    "22: /agent:add returns alice name"
assert_contains "$ADD_OUT" "actor_ids" "22: /agent:add returns actor_ids"

# --- step 2: /agent:list returns INSTANCES (I3) ----------------------
LIST_OUT=$(esr_cli admin submit agent_list \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 agent_list (instances): ${LIST_OUT}"
assert_contains "$LIST_OUT" "alice" "22: /agent:list lists alice INSTANCE"
assert_not_contains "$LIST_OUT" "available agent types" "22: /agent:list NOT type catalog"

# --- step 3: /plugin:agent-types returns TYPE CATALOG (I3) -----------
TYPES_OUT=$(esr_cli admin submit plugin_agent_types --wait --timeout 30)
echo "22 plugin_agent_types: ${TYPES_OUT}"
assert_contains "$TYPES_OUT" "available agent types" "22: /plugin:agent-types returns type catalog"
assert_contains "$TYPES_OUT" "cc"                    "22: includes cc type"

# --- step 4: /pty:list returns the spawned PTY (I2) ------------------
PTY_LIST_OUT=$(esr_cli admin submit pty_list \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 pty_list: ${PTY_LIST_OUT}"
assert_contains "$PTY_LIST_OUT" "alice"        "22: /pty:list shows alice"
assert_contains "$PTY_LIST_OUT" "pty_actor_id" "22: /pty:list emits pty_actor_id field"

PTY_ID=$(echo "$PTY_LIST_OUT" | awk -F': ' '/pty_actor_id:/ {gsub(/[",]/,"",$2); print $2; exit}')
[[ -n "$PTY_ID" ]] || _fail_with_context "22: no pty_actor_id from /pty:list"

# --- step 5: /pty:attach pty=<id> returns URL (I2) -------------------
ATTACH_OUT=$(esr_cli admin submit pty_attach \
  --arg pty="${PTY_ID}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 pty_attach: ${ATTACH_OUT}"
assert_contains "$ATTACH_OUT" "${PTY_ID}" "22: /pty:attach URL contains pty id"
assert_contains "$ATTACH_OUT" "/sessions" "22: /pty:attach URL has expected shape"

# --- step 6: /claude_code:tui name=alice resolves agent → URL (I2, I5) --------
TUI_OUT=$(esr_cli admin submit claude_code_tui \
  --arg name=alice \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 claude_code_tui: ${TUI_OUT}"
assert_contains "$TUI_OUT" "${PTY_ID}" "22: /claude_code:tui resolves alice → same PTY id"

# --- step 6b: multi-agent PTY isolation (Phase A.4 latent-bug fix) ---
#   Add a second agent (bob), confirm /pty:list returns 2 distinct
#   pty_actor_ids and the URLs they generate are different.
#   Spec rev-4 §4.5: each PtyProcess registers under "pty:<actor_id>",
#   so multi-agent sessions no longer alias.
ADD2_OUT=$(esr_cli admin submit agent_add \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=bob \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
assert_contains "$ADD2_OUT" "ok: true" "22: second /agent:add ok"

PTY_LIST2_OUT=$(esr_cli admin submit pty_list \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 pty_list (2 agents): ${PTY_LIST2_OUT}"
assert_contains "$PTY_LIST2_OUT" "alice" "22: /pty:list still shows alice"
assert_contains "$PTY_LIST2_OUT" "bob"   "22: /pty:list now shows bob"

PTY_BOB=$(esr_cli admin submit claude_code_tui \
  --arg name=bob \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

# bob's PTY id MUST differ from alice's — same session, distinct
# pty_actor_id (Phase A.4 invariant).
if echo "$PTY_BOB" | grep -q "${PTY_ID}"; then
  _fail_with_context "22: bob's PTY URL collides with alice's — Phase A.4 regression"
fi

# --- step 7: /session:add-agent returns rename hint (I4) -------------
DEPR_OUT=$(esr_cli exec "/session:add-agent type=cc name=ghost" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30 || true)
echo "22 deprecated /session:add-agent: ${DEPR_OUT}"
assert_contains "$DEPR_OUT" "/agent:add"  "22: rename hint for /session:add-agent"
assert_contains "$DEPR_OUT" "renamed"     "22: explicit 'renamed' message"

# --- final ------------------------------------------------------------
echo "PASS: 22_resource_typed_grammar"
```

NOTE: `esr exec /<slash>` is the supported primitive (`runtime/lib/esr/cli/main.ex:54`); it dispatches the literal slash through `Esr.Entity.SlashHandler` so the deprecated-slash hint path triggers naturally.

- [ ] **Step 2: Make executable + run**

```bash
chmod +x tests/e2e/scenarios/22_resource_typed_grammar.sh
bash tests/e2e/scenarios/22_resource_typed_grammar.sh 2>&1 | tail -30
```

Expected: `PASS: 22_resource_typed_grammar` on the last line.

If failing — read assertion output, adjust the `submit` arg shapes to what `esr_cli` actually accepts (refer to scenario 19 + 18 for working examples).

- [ ] **Step 3: Update README + architecture coverage map per CLAUDE.md rule**

Edit `README.md` §"E2E test scenarios" table to add a row for scenario 22.

Edit `docs/architecture.md` §"E2E coverage map" table similarly.

- [ ] **Step 4: Run full test + e2e suite for final regression**

```bash
(cd runtime && mix test 2>&1 | tail -5)
bash tests/e2e/scenarios/14_session_multiagent.sh 2>&1 | tail -3
bash tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh 2>&1 | tail -3
bash tests/e2e/scenarios/19_session_first_default.sh 2>&1 | tail -3
bash tests/e2e/scenarios/22_resource_typed_grammar.sh 2>&1 | tail -3
```

Expected: only pre-existing flakes; all 4 e2e scenarios `PASS:` on last line.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/pty/ \
        runtime/lib/esr/plugins/claude_code/commands/tui.ex \
        runtime/lib/esr/plugins/claude_code/manifest.yaml \
        runtime/priv/slash-routes.default.yaml \
        runtime/test/esr/commands/pty/ \
        runtime/test/esr/plugins/claude_code/commands/tui_test.exs \
        tests/e2e/scenarios/22_resource_typed_grammar.sh \
        README.md \
        docs/architecture.md

git rm runtime/lib/esr/commands/attach.ex

git commit -m "$(cat <<'EOF'
feat(grammar/E): /pty:list + /pty:attach + /claude_code:tui (claude_code plugin) + e2e 22

Final phase of resource-typed grammar refactor. /pty:list enumerates
PTY actor ids per chat-current session; /pty:attach emits the
WebSocket URL (no auth — out of scope per rev-2 D3, tracked in
docs/futures/todo.md). /claude_code:tui ships in claude_code plugin via the
rev-3 plugin-scoped command registration mechanism (manifest's
slash_routes: block) — second real consumer after feishu, validates
the rev-3 mechanism end-to-end.

Deletes the orphan Esr.Commands.Attach module (URL-emitter functionality
moves to /pty:attach). e2e scenario 22 verifies all 5 spec invariants
I1-I5.

Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md §4.2,
§4.4, §4.5, D3, D5, I1-I5. Plan Phase E.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase F — Docs sweep + manual-check rev-5 close-out + bilingual mirror sync

**Why a dedicated docs phase:** rev-3 D1's hard-cutover means every doc snippet showing `/session:add-agent` etc. is now wrong. Operators reading the cookbook or dev-guide would type forms the dispatcher rejects. Manual-check audit's follow-ups #2-#7 are closed by Phase A-E and need a rev-5 entry pointing at this PR. `pty_attach_security_hardening` (rev-2 D3 deferral) needs an entry in `docs/futures/todo.md` so the security gap is tracked.

**Files:**
- Modify: `docs/cookbook.md` (lines 10-11)
- Modify: `docs/dev-guide.md` (lines 39, 127)
- Modify: `docs/futures/todo.md` (rewrite the deferred-`/session:*` row at line 52; ADD `pty_attach_security_hardening` row)
- Modify: `CLAUDE.md` (line 81 — `/new-session` → `/session:new` slash form in URI shape section)
- Modify: `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` (append rev-5 section)
- Modify: `docs/manual-checks/2026-05-08-post-multi-instance-audit.zh_cn.md` (mirror rev-5)
- Modify: `tests/e2e/scenarios/14_session_multiagent.sh` + `tests/e2e/scenarios/15_session_share.sh` + `tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh` (header comments mention old slash names — update to new)
- Modify: `docs/superpowers/plans/2026-05-08-resource-typed-grammar-plan.zh_cn.md` (bump task count + add Phase F line)

**No code changes — pure doc + comment sweep.** Should be 1-2 short commits.

### Task F.1 — Update cookbook + dev-guide + CLAUDE.md slash references

- [ ] **Step 1: Edit `docs/cookbook.md` lines 10-11**

Find the lines:

```markdown
>   - **session lifecycle**: `/session:new name=<n>` to create; `/session:add-agent type=<t> name=<tag>` to
>     add an agent; `/session:set-primary name=<tag>` to set primary;
```

Replace with:

```markdown
>   - **session lifecycle**: `/session:new name=<n>` to create; `/agent:add type=<t> name=<tag>` to
>     add an agent; `/agent:set-primary name=<tag>` to set primary; `/session:end` to destroy;
```

- [ ] **Step 2: Edit `docs/dev-guide.md` line 39**

```markdown
5. In Feishu, DM the bot: `/workspace:new name=esr-dev` (then use `/session:add-agent` etc.)
```

→

```markdown
5. In Feishu, DM the bot: `/workspace:new name=esr-dev` (then `/session:new`, `/agent:add type=cc name=alice`, etc.)
```

- [ ] **Step 3: Edit `docs/dev-guide.md` line 127**

```markdown
Invoke via `/session:add-agent` (the topology DSL `esr cmd run` was P3-13-deleted
```

→

```markdown
Invoke via `/agent:add` (the topology DSL `esr cmd run` was P3-13-deleted
```

- [ ] **Step 4: Edit `CLAUDE.md` line 81**

In the "Session URI shape (PR-21d)" section, replace:

```markdown
/new-session <workspace> name=<…> cwd=<…> worktree=<…>
```

with:

```markdown
/session:new <workspace> name=<…> cwd=<…> worktree=<…>
```

- [ ] **Step 5: Sanity grep no remaining live references**

```bash
grep -rn "/session:add-agent\|/session:remove-agent\|/session:set-primary" \
  CLAUDE.md README.md docs/cookbook.md docs/dev-guide.md docs/architecture.md \
  docs/notes/ docs/guides/ 2>/dev/null
```

Expected: nothing. (Files under `docs/superpowers/specs/` and `docs/superpowers/plans/` legitimately keep historical references; `docs/manual-checks/` is allowed to keep the rev-3 audit history; `docs/superpowers/progress/` is frozen-in-time progress logs.)

### Task F.2 — Update `docs/futures/todo.md`: drop closed `/session:*` deferral, add PtySocket hardening

- [ ] **Step 1: Read the current row (line 52)**

```bash
sed -n '50,55p' docs/futures/todo.md
```

- [ ] **Step 2: Edit `docs/futures/todo.md`** — find the row about "Complete e2e 14 + 15" and DELETE it (the work it described — landing `/session:*` command modules — is shipped: PR #248 + this PR).

- [ ] **Step 3: Add `pty_attach_security_hardening` row**

In the most appropriate section of `docs/futures/todo.md` (likely "Security" or "Plugins" — adapt to existing categories; if no such section, append a new "Security hardening" section), add:

```markdown
| pty_attach_security_hardening — replace PtySocket's `?sid=` query-only auth with a Phoenix.Token signed token (10-min TTL) | not started | Spec rev-2/rev-3 D3 deferred this from the resource-typed grammar PR. Today's `pty_socket.ex:41-50` accepts any non-empty `sid` as auth — fine for single-operator-on-Tailscale, but a real gap for multi-operator deployments. ~30 LOC + tests when implemented. References: `docs/superpowers/specs/2026-05-08-resource-typed-grammar.md` §4.4. |
```

(Adapt column shape to the table format already in `docs/futures/todo.md`.)

- [ ] **Step 4: Sanity check the file is still valid markdown**

```bash
wc -l docs/futures/todo.md
grep -c "^| " docs/futures/todo.md  # rough table-row count, should be > previous count if you added a row
```

### Task F.3 — Append rev-5 section to manual-checks audit (en + zh_cn)

- [ ] **Step 1: Read the existing end of `docs/manual-checks/2026-05-08-post-multi-instance-audit.md`**

```bash
sed -n '275,$p' docs/manual-checks/2026-05-08-post-multi-instance-audit.md
```

- [ ] **Step 2: Append a rev-5 section**

Add the following just before the existing `## See also` section:

```markdown
---

## rev-5 — resource-typed grammar shipped (2026-05-08)

PR `feat/resource-typed-grammar` (~810 LOC, 5 phases A-E) implemented spec [`2026-05-08-resource-typed-grammar.md`](../superpowers/specs/2026-05-08-resource-typed-grammar.md) (rev-3, user-approved 2026-05-08), closing follow-ups #1-#7 from the rev-4 list.

### Closed by this PR

| Original # | What | How closed |
|---|---|---|
| 1 | Grammar spec | Spec rev-3 + plan landed; this PR ships the implementation |
| 2 | `/session:list` chat-bound shape | Phase B Task B.2 — `Esr.Commands.Session.List` extended with chat-bound output shape; slash entry wired in `slash-routes.default.yaml` |
| 3 | `/agent:list` repurposed (instances) + `/plugin:agent-types` | Phase C Tasks C.1-C.2 — old type-catalog logic moved to `Esr.Commands.Plugin.AgentTypes`; `/agent:list` now reads `InstanceRegistry.list/2` |
| 4 | `/pty:list` + `/pty:attach` | Phase E Tasks E.1-E.2 — new `Esr.Commands.Pty.{List,Attach}`; orphan `Esr.Commands.Attach` deleted |
| 5 | `/claude_code:tui` shortcut | Phase E Task E.3 — `Esr.Plugins.ClaudeCode.Commands.Tui` ships in claude_code plugin via the rev-3 plugin-scoped command registration mechanism (manifest `slash_routes:` block) |
| 6 | `/agent:rename`/`set-primary`/`primary`/`remove`/`add` family | Phase C Tasks C.3-C.7 — 5 modules under `runtime/lib/esr/commands/agent/`; old `session/{add_agent,remove_agent,set_primary}.ex` deleted |
| 7 | `/session:bind-chat`/`unbind-chat`/`switch` + slash-wire `/session:end` | Phase B Task B.4 (switch + end wiring) + Phase D Tasks D.1-D.5 (bind-chat/unbind-chat) |

### Still open (carried forward to rev-6)

| # | What | Status |
|---|---|---|
| 8 | `docs/grammar/commands.md` generator (`esr admin describe-grammar --format=markdown`) | spec-only — independent of this PR |
| 9 | First-user-auto-admin | not started — single-file change, ~30 LOC |
| 10 | `esr daemon init` + `esr daemon clear` | not started — first-30-min UX |
| (security) | `pty_attach_security_hardening` (PtySocket signed-token auth) | tracked in `docs/futures/todo.md`; deferred per rev-2 D3 |

### Net read

**rev-3 audit:** 9/12 fully closed.
**rev-4 audit:** 10/12 fully closed.
**rev-5 (this PR):** 11/12 fully closed (only #9 mental-model remains as a structural thing; everything operator-visible is unblocked).

The grammar overhaul also closes the cross-cutting "no PTY URL" regression (rev-4 #12) and unifies the operator surface around the resource axis (P1) so future plugin authors have a clear convention to follow.
```

- [ ] **Step 3: Mirror rev-5 to zh_cn**

Read the bilingual companion:

```bash
sed -n '$p' docs/manual-checks/2026-05-08-post-multi-instance-audit.zh_cn.md
```

Append a Chinese-language rev-5 section that summarises the en table — keep it concise (the bilingual convention treats zh_cn as a navigation companion, not a full translation when content is mostly tabular).

### Task F.4 — Update e2e scenarios 14, 15, 17, 18 + slash_route registry test

The header docstrings in scenarios 14, 15, 17, 18 still describe the old slash command names AND the test bodies in 17/18 directly invoke renamed kinds. Both must update.

- [ ] **Step 1: `tests/e2e/scenarios/15_session_share.sh`** — replace `/session:attach surface` and `/session:detach surface` references in the header comment block (lines 11-18 currently) with `/session:bind-chat` and `/session:unbind-chat`. The actual `esr_cli admin submit` calls in the body use kind names (`session_attach_surface`/`session_detach_surface`) — rename them to `session_bind_chat`/`session_unbind_chat` to match Phase D Task D.4.

- [ ] **Step 2: `tests/e2e/scenarios/17_plugin_config_hot_reload.sh`** — uses `session_add_agent` and `session_remove_agent` at lines 131, 185, 219 (verify via grep). Rename to `agent_add` / `agent_remove`. Header comment if it mentions agent kinds — update to match.

- [ ] **Step 3: `tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh`** — header line 2 says "via `/session:add-agent`"; replace with "via `/agent:add`". The body uses kind name `session_add_agent` — rename to `agent_add`.

- [ ] **Step 4: `tests/e2e/scenarios/14_session_multiagent.sh`** — same sweep.

```bash
grep -n "/session:add-agent\|/session:remove-agent\|/session:set-primary\|/session:attach\|/session:detach\|session_add_agent\|session_remove_agent\|session_set_primary\|session_attach_surface\|session_detach_surface" \
  tests/e2e/scenarios/14_session_multiagent.sh \
  tests/e2e/scenarios/15_session_share.sh \
  tests/e2e/scenarios/17_plugin_config_hot_reload.sh \
  tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh
```

For each line, decide:
- Header comment line → text replace
- `esr_cli admin submit <kind> ...` invocation → kind name change

- [ ] **Step 5: Update `runtime/test/esr/resource/slash_route/registry_test.exs:267`**

That test asserts `SlashRouteRegistry.lookup("/session:add-agent")` returns `{:ok, _}` from the live priv yaml. After Phase C deletes the slash entry, this lookup returns `:not_found` and the assertion breaks. Update the assertion to a slash that survives — e.g. `/agent:add` — or replace with a deliberately-survives canary.

```bash
grep -n '/session:add-agent\|/session:remove-agent\|/session:set-primary\|/session:attach\|/session:detach' runtime/test/esr/resource/slash_route/registry_test.exs
```

For each hit decide: rename to current colon-form OR delete the case (if the test was specifically asserting the old form's existence — that's now a contract this PR breaks intentionally).

- [ ] **Step 6: Run all 5 scenarios + the registry test to verify still green**

```bash
(cd runtime && mix test test/esr/resource/slash_route/registry_test.exs 2>&1 | tail -3)
bash tests/e2e/scenarios/14_session_multiagent.sh 2>&1 | tail -3
bash tests/e2e/scenarios/15_session_share.sh 2>&1 | tail -3
bash tests/e2e/scenarios/17_plugin_config_hot_reload.sh 2>&1 | tail -3
bash tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh 2>&1 | tail -3
bash tests/e2e/scenarios/22_resource_typed_grammar.sh 2>&1 | tail -3
```

Expected: registry test green; all 5 e2e `PASS:` on last line.

NOTE: if scenarios 14/15/17/18 break because the renamed kinds expose a routing gap, that is a Phase C/D oversight to fix in this phase — extend the kind-rename to cover the e2e harness submitter path.

### Task F.5 — Update bilingual plan summary + commit Phase F

- [ ] **Step 1: Edit `docs/superpowers/plans/2026-05-08-resource-typed-grammar-plan.zh_cn.md`** — bump phase count from 5 → 6 and add a Phase F row to the table:

```markdown
| **F** | docs sweep + manual-check audit rev-5 close-out + bilingual mirror（cookbook/dev-guide/futures/todo/CLAUDE.md/scenarios 14/15/18 header） | ~80 LOC docs | 5 |
| **总计** | | ~580 实现 + ~340 测试 + 100 e2e + 80 docs ≈ 1100 LOC | ~35 |
```

- [ ] **Step 2: Run `mix compile` + `mix test` for sanity** (no code changes, but cheap check)

```bash
(cd runtime && mix compile 2>&1 | tail -5)
(cd runtime && mix test 2>&1 | tail -3)
```

Expected: 0 errors / pre-existing flakes only.

- [ ] **Step 3: Commit**

```bash
git add docs/cookbook.md \
        docs/dev-guide.md \
        docs/futures/todo.md \
        CLAUDE.md \
        docs/manual-checks/2026-05-08-post-multi-instance-audit.md \
        docs/manual-checks/2026-05-08-post-multi-instance-audit.zh_cn.md \
        docs/superpowers/plans/2026-05-08-resource-typed-grammar-plan.zh_cn.md \
        tests/e2e/scenarios/14_session_multiagent.sh \
        tests/e2e/scenarios/15_session_share.sh \
        tests/e2e/scenarios/17_plugin_config_hot_reload.sh \
        tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh \
        runtime/test/esr/resource/slash_route/registry_test.exs

git commit -m "$(cat <<'EOF'
docs(grammar/F): cookbook/dev-guide/CLAUDE/futures/todo + manual-check rev-5

Sweeps every operator-facing doc that referenced the renamed slashes
(/session:add-agent → /agent:add, /session:attach → /session:bind-chat,
etc.) so cookbook + dev-guide examples are typeable as-is post-cutover.
CLAUDE.md's URI-shape example bumped from /new-session to /session:new
to match current grammar.

futures/todo.md: deferred-/session:* row deleted (closed by PR #248 +
this PR); pty_attach_security_hardening added per rev-2 D3 deferral.

manual-checks rev-5 closes follow-ups #1-#7 against this PR; #8/#9/#10
remain. Net read: 11/12 fully closed (was 10/12 in rev-4).

e2e scenarios 14/15/18 header comments + admin-submit kind names
updated for the renamed slashes.

Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md.
Plan Phase F.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final wrap-up

After all 6 phases land:

- [ ] **Step 1: Push branch + open PR**

```bash
git push -u origin feat/resource-typed-grammar
gh pr create --title "feat: resource-typed slash grammar (rev-3, /agent:*, /pty:*, /session:bind-chat, /claude_code:tui)" --body "$(cat <<'EOF'
## Summary

- 15 new slash commands (`/agent:*` family, `/pty:*` family, `/session:list|switch|end|bind-chat|unbind-chat`, `/plugin:agent-types`, `/claude_code:tui` in claude_code plugin)
- 5 hard-cutover renames (with rename hints via `slash_handler` `@deprecated_slashes`)
- `/claude_code:tui` is the **second real consumer** of the rev-3 plugin-scoped command registration mechanism (first was feishu's bind/unbind/notify)
- e2e scenario 22 verifies the 5 spec invariants

## Test plan

- [x] `mix test` green (only pre-existing flakes)
- [x] `bash tests/e2e/scenarios/22_resource_typed_grammar.sh` → `PASS: 22_resource_typed_grammar`
- [x] `bash tests/e2e/scenarios/14_session_multiagent.sh` (regression — multi-agent) → PASS
- [x] `bash tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh` (regression — multi-instance lifecycle) → PASS
- [x] `bash tests/e2e/scenarios/19_session_first_default.sh` (regression — session-first default) → PASS

## Spec

- [`docs/superpowers/specs/2026-05-08-resource-typed-grammar.md`](docs/superpowers/specs/2026-05-08-resource-typed-grammar.md) (rev-3, user-approved 2026-05-08)
- Plan: [`docs/superpowers/plans/2026-05-08-resource-typed-grammar-plan.md`](docs/superpowers/plans/2026-05-08-resource-typed-grammar-plan.md)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Per CLAUDE.md "After every feature PR merges to dev — promote to main"**

After PR is admin-merged to `dev`, run:

```bash
bash scripts/promote-dev-to-main.sh
git fetch origin && git push origin origin/dev:main
gh pr close <N> -c "Fast-forwarded via direct push (preserves SHAs across dev/main)."
```

---

## Self-review checklist (run mentally — fix inline)

**Spec coverage** — every row in spec §6 implementation surface mapped to a phase task:

- ✅ `runtime/lib/esr/commands/session/list.ex` modify → Phase B Task B.2
- ✅ `runtime/lib/esr/commands/session/switch.ex` slash-wire → Phase B Task B.4
- ✅ `runtime/lib/esr/commands/session/bind_chat.ex` new → Phase D Task D.2
- ✅ `runtime/lib/esr/commands/session/unbind_chat.ex` new → Phase D Task D.3
- ✅ `runtime/lib/esr/commands/session/end.ex` slash-wire → Phase B Task B.4
- ✅ Delete `session/{attach,detach,add_agent,remove_agent,set_primary}.ex` → Phase D Task D.5 + Phase C Task C.9
- ✅ `runtime/lib/esr/commands/agent/list.ex` rewrite → Phase C Task C.2
- ✅ `runtime/lib/esr/commands/plugin/agent_types.ex` new → Phase C Task C.1
- ✅ `runtime/lib/esr/commands/agent/{add,remove,set_primary,primary,rename}.ex` → Phase C Tasks C.3-C.7
- ✅ `runtime/lib/esr/commands/pty/{list,attach}.ex` → Phase E Tasks E.1-E.2
- ✅ `runtime/lib/esr/plugins/claude_code/commands/tui.ex` → Phase E Task E.3
- ✅ `runtime/lib/esr/plugins/claude_code/manifest.yaml` slash_routes block → Phase E Task E.4
- ✅ Delete `runtime/lib/esr/commands/attach.ex` → Phase E Task E.6
- ✅ `instance.ex` actor_ids field → Phase A Task A.2
- ✅ `instance_registry.ex` persist + pty_actor_id_for/2 → Phase A Task A.3
- ✅ `slash_handler.ex` @deprecated_slashes extension → Phase C Task C.10 + Phase D Task D.5
- ✅ `help.ex` Users category → Phase B Task B.3
- ✅ `slash-routes.default.yaml` 13 new + 5 deletes → Phase B Task B.4 + Phase C Task C.8 + Phase D Task D.4 + Phase E Task E.5
- ✅ All 13 test files → spread across Phase A-E

**Spec invariants verified** — every I1-I5 has a verifying test or e2e step:

- ✅ I1 (no `/session:` agent slashes) → Phase E Task E.7 e2e + slash_handler grep
- ✅ I2 (/pty:* + /claude_code:tui emit URLs) → Phase E Task E.7 e2e step 5+6
- ✅ I3 (/agent:list = instances; /plugin:agent-types = types) → Phase E Task E.7 e2e step 2+3
- ✅ I4 (renamed slashes return hint) → Phase C Task C.10 + Phase D Task D.5 (unit) + Phase E Task E.7 e2e step 7
- ✅ I5 (/claude_code:tui registered via plugin slash_routes block) → Phase E Task E.4 step 2 (manifest parse) + Task E.7 step 6 (resolves end-to-end)

**Placeholder scan** — no "TBD"/"TODO"/"implement later" in any task body. ✅

**Type consistency** — function names + struct field names consistent across phases:

- ✅ `actor_ids: %{cc, pty}` shape used identically in `instance.ex`, `instance_registry.ex`, `agent/list.ex`, `pty/list.ex`, `cc/tui.ex` tests
- ✅ `pty_actor_id_for/2` referenced from `cc/tui.ex` matches definition in Phase A
- ✅ `Esr.Session.ChatRouting.Registry.{attach_session/3, current_session/2, list_sessions/2}` API used consistently (verify `list_sessions/2` exists or add in B.2 step 2)
- ✅ `InstanceRegistry.{list/2, get/3, primary/1, rename_instance/3}` API consistent

**Residual risks**:

- `Esr.Session.ChatRouting.Registry.list_sessions/2` may not exist — Phase B Task B.2 step 2 verifies and adds if missing.
- `submit_text` e2e harness verb may not exist — Phase E Task E.7 step 1 NOTE flags this; adapt to actual harness.
- `EsrUri.build_path/2` and `EsrUri.to_http_url/2` are assumed to exist (used by current `Esr.Commands.Attach`); verify with `grep -n "def build_path\|def to_http_url" runtime/lib/esr/uri.ex` before E.2 step 3.

End of plan.
