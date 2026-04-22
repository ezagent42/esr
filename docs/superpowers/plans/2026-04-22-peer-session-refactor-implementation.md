# Peer/Session Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor ESR's Elixir runtime to a typed Peer behaviour model with AdminSession + user Sessions, OSProcess底座 via MuonTrap, and yaml-driven agent definitions — eliminating the current ad-hoc routing and the misplaced `SessionRouter`.

**Architecture:** Three-tier supervision: (1) `Esr.Supervisor` at top, (2) `Esr.AdminSession` holds global-scope peers (FeishuAppAdapter, SlashHandler, voice pools), (3) `Esr.SessionsSupervisor` dynamically spawns user `Session_<ulid>` supervisors per `/new-session`. Peers communicate via injected neighbor refs (no central router on hot path). Control plane: `Esr.PeerFactory` (creation), `Esr.SessionRouter` (lifecycle decisions), `Esr.SessionRegistry` (yaml-compiled agent definitions + mappings).

**Tech Stack:** Elixir 1.19 / OTP 27 / Phoenix 1.8 / Bandit (HTTP); MuonTrap (Hex pkg, OS process wrapping); tmux `-C` control mode; Python 3.11+ via `uv`; `:file_system` for yaml hot-reload.

**Spec:** `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` (v3.1). Read before starting any task.

---

## Plan Structure

This plan uses **progressive expansion**:

- **PR-0 (rename surgery)** and **PR-1 (foundations)** are detailed to bite-sized TDD steps (sections below).
- **PR-2..PR-5** are task-level outlines with file lists, acceptance criteria, and design references (sections further below). When PR-1 merges, re-expand PR-2's outline into bite-sized steps using the actual API shapes that PR-1 produced. Repeat for each subsequent PR.
- Reason: API shapes for later PRs depend on earlier PR outputs. Locking bite-sized steps in advance for all 70+ tasks creates brittle plan content that will need rewriting anyway.

**Execution:** Use `superpowers:subagent-driven-development` with a fresh subagent per task and two-stage review between tasks. Work lives in the `feature/peer-session-refactor` worktree at `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/`.

---

## File Structure (full refactor)

### Created files (Elixir — all under `runtime/lib/esr/`)

| Path | Responsibility | PR |
|---|---|---|
| `peer.ex` | `Esr.Peer` — base behaviour + metadata | PR-1 |
| `peer/proxy.ex` | `Esr.Peer.Proxy` — stateless forwarder behaviour + compile-time macro | PR-1 |
| `peer/stateful.ex` | `Esr.Peer.Stateful` — stateful peer behaviour | PR-1 |
| `os_process.ex` | `Esr.OSProcess` — OS-process底座 behaviour | PR-1 |
| `tmux_process.ex` | `Esr.TmuxProcess` — OSProcess impl for tmux `-C` mode | PR-1 |
| `py_process.ex` | `Esr.PyProcess` — OSProcess impl for Python sidecars via `uv run python -m` | PR-1 |
| `peer_factory.ex` | `Esr.PeerFactory` — thin DynamicSupervisor.start_child wrapper | PR-1 |
| `peer_pool.ex` | `Esr.PeerPool` — pooled workers, default `max_workers: 128` | PR-1 |
| `session_router.ex` | `Esr.SessionRouter` — control plane (NEW file at this path; different from the old routing/session_router.ex) | PR-3 |
| `session_socket_registry.ex` | `Esr.SessionSocketRegistry` — renamed from old `SessionRegistry` | PR-1 |
| `admin_session.ex` | `Esr.AdminSession` — top-level permanent supervisor | PR-2 |
| `admin_session_process.ex` | `Esr.AdminSessionProcess` — admin-session-level state | PR-2 |
| `session.ex` | `Esr.Session` — supervisor module for per-user Session subtrees | PR-2 |
| `session_process.ex` | `Esr.SessionProcess` — session-level state | PR-2 |
| `sessions_supervisor.ex` | `Esr.SessionsSupervisor` — DynamicSupervisor with `max_children: 128` | PR-2 |
| `peers/feishu_app_adapter.ex` | `Esr.Peers.FeishuAppAdapter` — Peer.Stateful, Feishu WebSocket edge | PR-2 |
| `peers/feishu_chat_proxy.ex` | `Esr.Peers.FeishuChatProxy` — Peer.Stateful, session inbound + slash detection | PR-2 |
| `peers/feishu_app_proxy.ex` | `Esr.Peers.FeishuAppProxy` — Peer.Proxy, outbound to AdminSession's FeishuAppAdapter | PR-2 |
| `peers/slash_handler.ex` | `Esr.Peers.SlashHandler` — Peer.Stateful, channel-agnostic slash parser | PR-2 |
| `peers/cc_proxy.ex` | `Esr.Peers.CCProxy` — Peer.Proxy | PR-3 |
| `peers/cc_process.ex` | `Esr.Peers.CCProcess` — Peer.Stateful, CC session brain | PR-3 |
| `peers/tmux_process.ex` | `Esr.Peers.TmuxProcess` — Peer.Stateful + OSProcess composition | PR-3 |
| `peers/voice_asr.ex` + `peers/voice_asr_proxy.ex` | Voice ASR peer + proxy | PR-4a |
| `peers/voice_tts.ex` + `peers/voice_tts_proxy.ex` | Voice TTS peer + proxy | PR-4a |
| `peers/voice_e2e.ex` | Voice E2E peer | PR-4a |

### Modified files (Elixir)

| Path | Change | PR |
|---|---|---|
| `runtime/lib/esr/session_registry.ex` | Gutted; new content = yaml compiler + mapping registry | PR-1 (rename old content to session_socket_registry.ex first) |
| `runtime/lib/esr/application.ex` | Supervision tree updated per §4 | PR-1 initial additions; PR-2/PR-3 extend |
| `runtime/lib/esr/admin/commands/session/new.ex` | Require `agent` field; reject without it | PR-3 |
| `runtime/lib/esr/admin/commands/session/end.ex` | Adapt to new Session supervisor tree | PR-3 |
| `runtime/mix.exs` | Add `{:muontrap, "~> 1.3"}` dep | PR-1 |
| `runtime/lib/esr/routing/session_router.ex` | (PR-0) rename module to `Esr.Routing.SlashHandler` + file rename | PR-0 |
| `runtime/test/esr/routing/session_router_test.exs` | (PR-0) rename references | PR-0 |

### Deleted files (Elixir)

| Path | When | Why |
|---|---|---|
| `runtime/lib/esr/adapter_hub/registry.ex` | PR-2 | Subsumed by `SessionRegistry` |
| `runtime/lib/esr/adapter_hub/supervisor.ex` | PR-2 | No children left |
| `runtime/lib/esr/topology/registry.ex` | PR-3 | Merged into `SessionRegistry` |
| `runtime/lib/esr/topology/instantiator.ex` | PR-3 | Absorbed by `SessionRouter.create_session` + `PeerFactory` |
| `runtime/lib/esr/topology/supervisor.ex` | PR-3 | No children left |
| `runtime/lib/esr/routing/slash_handler.ex` (the renamed file from PR-0) | PR-3 | Superseded by `Esr.Peers.SlashHandler` |

### Python changes

| Path | Change | PR |
|---|---|---|
| `py/voice_gateway/` | Delete after split | PR-4a |
| `py/voice_asr/` | New sidecar (ASR) | PR-4a |
| `py/voice_tts/` | New sidecar (TTS) | PR-4a |
| `py/voice_e2e/` | New sidecar (E2E) | PR-4a |
| `py/src/esr/ipc/adapter_runner.py` | Delete after split | PR-4b |
| `py/feishu_adapter_runner/` | New sidecar | PR-4b |
| `py/cc_adapter_runner/` | New sidecar | PR-4b |
| `py/generic_adapter_runner/` | New sidecar (catch-all, deprecated on arrival) | PR-4b |

### Config files

| Path | When | Purpose |
|---|---|---|
| `${ESRD_HOME}/${instance}/agents.yaml` | PR-2 (schema validator) | Agent definitions per §3.5 of spec |
| `${ESRD_HOME}/${instance}/pools.yaml` (optional) | PR-4a | Pool-size overrides |

---

## PR Dependency Graph

```
main
 │
 ├── PR-0: rename surgery (on feature/dev-prod-isolation, squash-merges into main via PR #11)
 │   └── main updated
 │
 └── feature/peer-session-refactor (this worktree, branched from main)
     │
     ├── PR-1 (foundations, 3-4d)
     │   └── sub-branches off for PR-2..PR-5
     │
     ├── PR-2 (Feishu chain + AdminSession, 4-5d) — depends on PR-1
     │
     ├── PR-3 (CC chain + SessionRouter + Topology removal, 4-5d) — depends on PR-2
     │
     ├── PR-4a (voice-gateway split, 3-4d) — parallel to PR-3 after PR-2
     │
     ├── PR-4b (adapter_runner split, 2-3d) — parallel to PR-3/PR-4a after PR-2
     │
     └── PR-5 (cleanup + docs, 2-3d) — depends on everything above
```

Total critical path: PR-1 → PR-2 → PR-3 → PR-5 ≈ 14 days.
Full calendar (with PR-4a/b parallel to PR-3): 14-18 days.

---

# PR-0: Rename Surgery

**Worktree:** `/Users/h2oslabs/Workspace/esr/.worktrees/dev-prod-isolation/` (current PR #11 branch: `feature/dev-prod-isolation`)

**Goal:** Rename the misplaced `Esr.Routing.SessionRouter` to `Esr.Routing.SlashHandler` so that the correct name lands on `main` when PR #11 merges. Behaviour unchanged.

**Acceptance gates** (from spec §10.5):
- `mix test` fully green
- `rg "Esr.Routing.SessionRouter"` returns only comments/docs
- No new test files; test files renamed in lockstep with modules

### Task P0-1: Rename the module file

**Files:**
- Rename: `runtime/lib/esr/routing/session_router.ex` → `runtime/lib/esr/routing/slash_handler.ex`
- Edit contents: replace `Esr.Routing.SessionRouter` → `Esr.Routing.SlashHandler` (module declaration + any self-references)

- [ ] **Step 1: rename file**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev-prod-isolation
git mv runtime/lib/esr/routing/session_router.ex runtime/lib/esr/routing/slash_handler.ex
```

- [ ] **Step 2: update module name inside the file**

Open `runtime/lib/esr/routing/slash_handler.ex`. Replace `defmodule Esr.Routing.SessionRouter do` with `defmodule Esr.Routing.SlashHandler do`. Also update the `@moduledoc` to reflect: "Slash command parser — currently the only kind of message routing this module does. Forwards parsed commands to `Esr.Admin.Dispatcher` via cast+correlation-ref. Will be replaced by `Esr.Peers.SlashHandler` in the Peer/Session refactor (see `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`)."

- [ ] **Step 3: grep and replace all module references across the codebase**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev-prod-isolation
rg -l "Esr.Routing.SessionRouter" | xargs sed -i '' 's/Esr\.Routing\.SessionRouter/Esr.Routing.SlashHandler/g'
```

Verify:
```bash
rg "Esr.Routing.SessionRouter"
# Expected: empty, or only inside this spec/plan file as historical references
```

- [ ] **Step 4: rename the test file**

```bash
git mv runtime/test/esr/routing/session_router_test.exs runtime/test/esr/routing/slash_handler_test.exs
```

- [ ] **Step 5: update describe/test names inside the test file**

Open `runtime/test/esr/routing/slash_handler_test.exs`. Replace `describe "SessionRouter ..."` etc. with `describe "SlashHandler ..."` (preserves test semantics; only module name changes). Also update any `alias Esr.Routing.SessionRouter` → `alias Esr.Routing.SlashHandler`.

- [ ] **Step 6: run the full test suite**

```bash
cd runtime
mix test
```

Expected: all tests pass. If any test references the old name via string (e.g., `assert_receive {:message, Esr.Routing.SessionRouter, _}`), fix it.

- [ ] **Step 7: grep for any remaining references**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev-prod-isolation
rg "Esr.Routing.SessionRouter"
```

Expected: only matches inside `docs/` (historical references in specs/plans are fine).

- [ ] **Step 8: commit**

```bash
git add -A
git commit -m "refactor: rename Esr.Routing.SessionRouter to Esr.Routing.SlashHandler

Preserves PR #11's behaviour but uses a name that describes what the
module actually does (parse slash commands). The refactor that creates
a real SessionRouter is tracked separately in
docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P0-2: Update spec cross-references in v2.2 doc

**Files:**
- Modify: `docs/superpowers/specs/2026-04-21-esr-dev-prod-isolation-design.md`

- [ ] **Step 1: search for `SessionRouter` mentions in v2.2**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev-prod-isolation
rg "SessionRouter" docs/superpowers/specs/2026-04-21-esr-dev-prod-isolation-design.md
```

- [ ] **Step 2: add a note at the top of v2.2 spec**

Insert after the `Change log` section:

```markdown
> **Note (2026-04-22):** The `Esr.Routing.SessionRouter` introduced by v2.2 Task 17 has been renamed to `Esr.Routing.SlashHandler` (cosmetic change only; behaviour unchanged). The real SessionRouter (control-plane actor) is defined in the Peer/Session refactor spec (`2026-04-22-peer-session-refactor-design.md`) and lands post-merge of PR #11.
```

- [ ] **Step 3: commit**

```bash
git add docs/superpowers/specs/2026-04-21-esr-dev-prod-isolation-design.md
git commit -m "docs(spec): note SessionRouter→SlashHandler rename and v3.0 refactor

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P0-3: Final verification + push

- [ ] **Step 1: run full test suite one more time**

```bash
cd runtime && mix test
```

Expected: all green.

- [ ] **Step 2: push to remote**

```bash
git push origin feature/dev-prod-isolation
```

- [ ] **Step 3: wait for CI green on PR #11**

Open https://github.com/ezagent42/esr/pull/11 and confirm CI is green with the rename commits.

- [ ] **Step 4: request squash-merge of PR #11**

Comment on PR #11: "Rename surgery complete; SessionRouter → SlashHandler. Ready to squash-merge. Peer/Session refactor continues on `feature/peer-session-refactor`."

**PR-0 done.**

---

# PR-1: Peer Behaviours + OSProcess底座 + SessionRegistry Skeleton

**Worktree:** `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/` (branch: `feature/peer-session-refactor`)

**Goal:** Ship the new foundations without changing production runtime behaviour. Every new module has full test coverage; no existing caller uses them yet. After this PR merges to `feature/peer-session-refactor`, subsequent PRs migrate callers.

**Prereq:** PR-0 merged to main. Rebase this worktree on main before starting: `git fetch origin && git rebase origin/main`.

**Acceptance gates** (spec §10.5 PR-1):
- `mix test` green
- `Peer.Proxy` macro compile-error test passes
- OSProcess cleanup integration test: kill peer → OS process dies ≤10s
- TmuxProcess control-mode integration test: start + receive `%output` + clean exit
- PyProcess integration test: start dummy Python sidecar + JSON-line round-trip
- SessionRegistry: yaml parse + hot-reload works
- PeerFactory unit tests pass
- MuonTrap dep added

### Task P1-1: Add MuonTrap dependency + baseline test run

**Files:**
- Modify: `runtime/mix.exs`
- Modify: `runtime/mix.lock` (regenerated)

- [ ] **Step 1: add MuonTrap to deps**

Open `runtime/mix.exs`. In the `defp deps do` list, add:
```elixir
{:muontrap, "~> 1.3"}
```

- [ ] **Step 2: fetch**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/runtime
mix deps.get
```

Expected: `muontrap` appears in `mix.lock`. No other changes expected.

- [ ] **Step 3: run full baseline tests**

```bash
mix test
```

Expected: all tests pass (we just added a dep, no code changes yet).

- [ ] **Step 4: commit**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
git add runtime/mix.exs runtime/mix.lock
git commit -m "feat(runtime): add muontrap dependency for OSProcess底座

Preparing for the Peer/Session refactor's OSProcess behaviour which
wraps tmux and python sidecar processes with muontrap for guaranteed
cleanup on BEAM exit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-2: Create `Esr.Peer` base behaviour

**Files:**
- Create: `runtime/lib/esr/peer.ex`
- Create: `runtime/test/esr/peer_test.exs`

- [ ] **Step 1: write the failing test**

Create `runtime/test/esr/peer_test.exs`:

```elixir
defmodule Esr.PeerTest do
  use ExUnit.Case, async: true

  describe "Esr.Peer" do
    test "defines common metadata helpers" do
      # A module using either Peer.Proxy or Peer.Stateful gains a
      # peer_kind/0 helper that returns :proxy or :stateful.
      defmodule TestProxy do
        use Esr.Peer.Proxy
        def forward(_msg, _ctx), do: :ok
      end
      defmodule TestStateful do
        use Esr.Peer.Stateful
        def init(_), do: {:ok, %{}}
        def handle_upstream(_, state), do: {:forward, [], state}
        def handle_downstream(_, state), do: {:forward, [], state}
      end

      assert TestProxy.peer_kind() == :proxy
      assert TestStateful.peer_kind() == :stateful
    end

    test "Peer module exposes peer_kind/0 callback typing" do
      # The base module defines the @callback peer_kind/0 :: :proxy | :stateful
      assert {:peer_kind, 0} in Esr.Peer.behaviour_info(:callbacks)
    end
  end
end
```

- [ ] **Step 2: run test to verify it fails**

```bash
cd runtime
mix test test/esr/peer_test.exs
```

Expected: FAIL with "module Esr.Peer is not loaded" or similar.

- [ ] **Step 3: write minimal implementation**

Create `runtime/lib/esr/peer.ex`:

```elixir
defmodule Esr.Peer do
  @moduledoc """
  Base behaviour for all Peers.

  Peers are actors that implement one of `Esr.Peer.Proxy` or `Esr.Peer.Stateful`.
  Every Peer belongs to exactly one Session (user Session or `AdminSession`).

  See `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.1.
  """

  @type peer_kind :: :proxy | :stateful

  @callback peer_kind() :: peer_kind()

  @doc "Common helpers for modules using Peer.Proxy or Peer.Stateful."
  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)

    quote do
      @behaviour Esr.Peer

      @impl Esr.Peer
      def peer_kind, do: unquote(kind)
    end
  end
end
```

- [ ] **Step 4: implement stub Peer.Proxy and Peer.Stateful to satisfy the test**

Create `runtime/lib/esr/peer/proxy.ex`:

```elixir
defmodule Esr.Peer.Proxy do
  @moduledoc """
  Stateless forwarder Peer.

  Compile-time restricted: a module using `Esr.Peer.Proxy` cannot
  define `handle_call/3` or `handle_cast/2` — doing so raises a
  compile error. This enforces the "proxies never accumulate state"
  rule.

  See spec §3.1.
  """

  @callback forward(msg :: term(), ctx :: map()) ::
              :ok | {:drop, reason :: atom()}

  defmacro __using__(_opts) do
    quote do
      use Esr.Peer, kind: :proxy
      @behaviour Esr.Peer.Proxy

      # Compile-time check: reject stateful callbacks.
      # Implementation deferred to Task P1-3 (will use @before_compile + __ENV__).
    end
  end
end
```

Create `runtime/lib/esr/peer/stateful.ex`:

```elixir
defmodule Esr.Peer.Stateful do
  @moduledoc """
  Peer with state and/or side effects.

  See spec §3.1.
  """

  @callback init(peer_args :: map()) ::
              {:ok, state :: term()} | {:stop, reason :: term()}

  @callback handle_upstream(msg :: term(), state :: term()) ::
              {:forward, [term()], term()}
              | {:reply, term(), term()}
              | {:drop, atom(), term()}

  @callback handle_downstream(msg :: term(), state :: term()) ::
              {:forward, [term()], term()}
              | {:drop, atom(), term()}

  defmacro __using__(_opts) do
    quote do
      use Esr.Peer, kind: :stateful
      @behaviour Esr.Peer.Stateful
    end
  end
end
```

- [ ] **Step 5: run test**

```bash
mix test test/esr/peer_test.exs
```

Expected: PASS.

- [ ] **Step 6: commit**

```bash
git add runtime/lib/esr/peer.ex runtime/lib/esr/peer/ runtime/test/esr/peer_test.exs
git commit -m "feat(peer): add Esr.Peer base behaviour + Proxy/Stateful stubs

Defines the peer_kind/0 callback and use-macros that later
Peer modules consume. Proxy compile-time callback-rejection
logic is added in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-3: `Peer.Proxy` compile-time callback rejection

**Files:**
- Modify: `runtime/lib/esr/peer/proxy.ex`
- Create: `runtime/test/esr/peer/proxy_compile_test.exs`

- [ ] **Step 1: write the failing test**

Create `runtime/test/esr/peer/proxy_compile_test.exs`:

```elixir
defmodule Esr.Peer.ProxyCompileTest do
  use ExUnit.Case, async: false

  test "Peer.Proxy module rejects handle_call/3 at compile time" do
    ast =
      quote do
        defmodule BadProxy1 do
          use Esr.Peer.Proxy
          def forward(_msg, _ctx), do: :ok
          def handle_call(_msg, _from, state), do: {:reply, :ok, state}
        end
      end

    assert_raise CompileError, ~r/Peer\.Proxy .* cannot define stateful callbacks/, fn ->
      Code.compile_quoted(ast)
    end
  end

  test "Peer.Proxy module rejects handle_cast/2 at compile time" do
    ast =
      quote do
        defmodule BadProxy2 do
          use Esr.Peer.Proxy
          def forward(_msg, _ctx), do: :ok
          def handle_cast(_msg, state), do: {:noreply, state}
        end
      end

    assert_raise CompileError, ~r/Peer\.Proxy .* cannot define stateful callbacks/, fn ->
      Code.compile_quoted(ast)
    end
  end

  test "Peer.Proxy module compiles fine with only forward/2" do
    ast =
      quote do
        defmodule GoodProxy do
          use Esr.Peer.Proxy
          def forward(_msg, _ctx), do: :ok
        end
      end

    assert [{GoodProxy, _}] = Code.compile_quoted(ast)
  end
end
```

- [ ] **Step 2: run test to verify it fails**

```bash
mix test test/esr/peer/proxy_compile_test.exs
```

Expected: FAIL (all three tests, because macro doesn't enforce anything yet).

- [ ] **Step 3: implement compile-time check**

Replace `runtime/lib/esr/peer/proxy.ex` content:

```elixir
defmodule Esr.Peer.Proxy do
  @moduledoc """
  Stateless forwarder Peer.

  Compile-time restricted: a module using `Esr.Peer.Proxy` cannot
  define `handle_call/3` or `handle_cast/2`. This enforces "proxies
  never accumulate state".

  See spec §3.1.
  """

  @callback forward(msg :: term(), ctx :: map()) ::
              :ok | {:drop, reason :: atom()}

  @forbidden [{:handle_call, 3}, {:handle_cast, 2}]

  defmacro __using__(_opts) do
    quote do
      use Esr.Peer, kind: :proxy
      @behaviour Esr.Peer.Proxy
      @before_compile Esr.Peer.Proxy
    end
  end

  defmacro __before_compile__(env) do
    defined = Module.definitions_in(env.module, :def)

    offenders =
      for fa <- @forbidden, fa in defined, do: fa

    if offenders != [] do
      msg =
        "Esr.Peer.Proxy module #{inspect(env.module)} cannot define stateful callbacks. " <>
          "Found: #{inspect(offenders)}. Use Esr.Peer.Stateful if you need state."

      raise CompileError,
        description: msg,
        file: env.file,
        line: env.line
    end

    :ok
  end
end
```

- [ ] **Step 4: run test**

```bash
mix test test/esr/peer/proxy_compile_test.exs
```

Expected: all three tests PASS.

- [ ] **Step 5: run full suite to ensure nothing else broke**

```bash
mix test
```

Expected: all green.

- [ ] **Step 6: commit**

```bash
git add runtime/lib/esr/peer/proxy.ex runtime/test/esr/peer/proxy_compile_test.exs
git commit -m "feat(peer): enforce Peer.Proxy compile-time ban on stateful callbacks

Risk B mitigation (spec §6): Proxy modules cannot accidentally grow
handle_call/3 or handle_cast/2. Attempting to do so fails compilation
with a clear error message.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-4: `Peer.Stateful` callback dispatch harness

**Files:**
- Create: `runtime/test/esr/peer/stateful_test.exs`
- Modify: `runtime/lib/esr/peer/stateful.ex`

- [ ] **Step 1: write tests for init/handle_upstream/handle_downstream flow**

Create `runtime/test/esr/peer/stateful_test.exs`:

```elixir
defmodule Esr.Peer.StatefulTest do
  use ExUnit.Case, async: true

  defmodule SumPeer do
    use Esr.Peer.Stateful

    @impl true
    def init(_), do: {:ok, %{total: 0}}

    @impl true
    def handle_upstream({:add, n}, state) do
      new = %{state | total: state.total + n}
      {:forward, [{:total, new.total}], new}
    end

    @impl true
    def handle_downstream({:reset}, _state), do: {:forward, [], %{total: 0}}
  end

  test "Peer.Stateful modules expose the behaviour callbacks" do
    assert {:init, 1} in SumPeer.module_info(:exports)
    assert {:handle_upstream, 2} in SumPeer.module_info(:exports)
    assert {:handle_downstream, 2} in SumPeer.module_info(:exports)
  end

  test "init returns the initial state" do
    assert {:ok, %{total: 0}} = SumPeer.init(%{})
  end

  test "handle_upstream updates state and emits forward msg" do
    {:ok, s0} = SumPeer.init(%{})
    assert {:forward, [{:total, 5}], %{total: 5}} = SumPeer.handle_upstream({:add, 5}, s0)
  end

  test "peer_kind/0 is :stateful" do
    assert SumPeer.peer_kind() == :stateful
  end
end
```

- [ ] **Step 2: run test**

```bash
mix test test/esr/peer/stateful_test.exs
```

Expected: PASS (stubs from Task P1-2 already satisfy the behaviour).

- [ ] **Step 3: commit**

```bash
git add runtime/test/esr/peer/stateful_test.exs
git commit -m "test(peer): exercise Peer.Stateful init/handle_upstream/handle_downstream

Verifies the behaviour callbacks are wired correctly and a fixture
peer's state transitions work as specified.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-5: `Esr.OSProcess` behaviour + MuonTrap integration

**Files:**
- Create: `runtime/lib/esr/os_process.ex`
- Create: `runtime/test/esr/os_process_test.exs`

- [ ] **Step 1: write a test using a fixture that wraps `/bin/sleep`**

Create `runtime/test/esr/os_process_test.exs`:

```elixir
defmodule Esr.OSProcessTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule SleepPeer do
    use Esr.Peer.Stateful
    use Esr.OSProcess, kind: :test_sleep

    @impl Esr.Peer.Stateful
    def init(%{} = args), do: {:ok, %{dur: args[:dur] || 30}}

    @impl Esr.Peer.Stateful
    def handle_upstream(_, state), do: {:forward, [], state}
    @impl Esr.Peer.Stateful
    def handle_downstream(_, state), do: {:forward, [], state}

    @impl Esr.OSProcess
    def os_cmd(state), do: ["sleep", Integer.to_string(state.dur)]
    @impl Esr.OSProcess
    def os_env(_state), do: []
    @impl Esr.OSProcess
    def on_os_exit(0, _state), do: {:stop, :normal}
    def on_os_exit(status, _state), do: {:stop, {:exited, status}}
  end

  test "os_cmd wraps the OS process via MuonTrap and returns pid/os_pid" do
    {:ok, pid} = GenServer.start_link(SleepPeer.OSProcessWorker, %{dur: 5})
    {:ok, os_pid} = GenServer.call(pid, :os_pid)
    assert is_integer(os_pid) and os_pid > 0

    # Confirm the process exists
    assert {_, 0} = System.cmd("ps", ["-p", Integer.to_string(os_pid)])
    GenServer.stop(pid, :normal)
  end

  test "killing the Elixir GenServer cleans up the OS process within 10s" do
    {:ok, pid} = GenServer.start_link(SleepPeer.OSProcessWorker, %{dur: 60})
    {:ok, os_pid} = GenServer.call(pid, :os_pid)

    Process.exit(pid, :kill)

    # Poll up to 10s
    Enum.reduce_while(1..20, nil, fn _i, _ ->
      case System.cmd("ps", ["-p", Integer.to_string(os_pid)]) do
        {_, 0} -> :timer.sleep(500); {:cont, nil}
        {_, _} -> {:halt, :gone}
      end
    end)
    |> case do
      :gone -> :ok
      _     -> flunk("OS process #{os_pid} still alive after 10s")
    end
  end
end
```

- [ ] **Step 2: run test**

```bash
mix test test/esr/os_process_test.exs --only integration
```

Expected: FAIL with "module Esr.OSProcess is not loaded" or similar.

- [ ] **Step 3: implement OSProcess behaviour + its inner worker**

Create `runtime/lib/esr/os_process.ex`:

```elixir
defmodule Esr.OSProcess do
  @moduledoc """
  Composition底座 for Peers that wrap one OS process.

  A Peer that uses `Esr.OSProcess` gains an embedded worker module
  (`<PeerModule>.OSProcessWorker`) which supervises the OS process
  via `MuonTrap.Daemon`. The Peer's lifecycle controls the OS process's
  lifecycle: when the Peer dies, the OS process is terminated within 5s.

  See spec §3.2.
  """

  @callback os_cmd(state :: term()) :: [String.t()]
  @callback os_env(state :: term()) :: [{String.t(), String.t()}]
  @callback on_os_exit(exit_status :: non_neg_integer(), state :: term()) ::
              {:stop, reason :: term()} | {:restart, new_state :: term()}

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)

    quote do
      @behaviour Esr.OSProcess
      @os_process_kind unquote(kind)

      defmodule OSProcessWorker do
        @moduledoc false
        use GenServer

        alias MuonTrap.Daemon

        def start_link(init_args), do: GenServer.start_link(__MODULE__, init_args)

        @impl true
        def init(init_args) do
          parent = __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()
          {:ok, state} = parent.init(init_args)

          [exe | args] = parent.os_cmd(state)
          env = parent.os_env(state)

          {:ok, daemon} =
            Daemon.start_link(exe, args,
              env: env,
              log_output: :debug,
              exit_status_to_reason: &{:os_exit, &1}
            )

          Process.monitor(daemon)
          os_pid = Daemon.os_pid(daemon)

          {:ok, %{parent: parent, state: state, daemon: daemon, os_pid: os_pid}}
        end

        @impl true
        def handle_call(:os_pid, _from, s), do: {:reply, {:ok, s.os_pid}, s}

        @impl true
        def handle_info({:DOWN, _ref, :process, daemon, {:os_exit, status}}, %{daemon: daemon} = s) do
          case s.parent.on_os_exit(status, s.state) do
            {:stop, reason} -> {:stop, reason, s}
            {:restart, _new_state} -> {:stop, :restart_not_yet_implemented, s}
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: run test**

```bash
mix test test/esr/os_process_test.exs --only integration
```

Expected: both tests PASS. If the second test fails with a timeout, MuonTrap may not be cleaning up on macOS — investigate with `ps aux | grep sleep` manually.

- [ ] **Step 5: run full suite**

```bash
mix test
```

Expected: all green.

- [ ] **Step 6: commit**

```bash
git add runtime/lib/esr/os_process.ex runtime/test/esr/os_process_test.exs
git commit -m "feat(os_process): Esr.OSProcess底座 via MuonTrap

Composition macro that injects an OSProcessWorker GenServer into any
Peer module needing to wrap an OS process. Cleanup is automatic on
Elixir exit: integration test asserts OS process dies <10s after
GenServer is killed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-6: `Esr.TmuxProcess` implementation + control-mode integration test

**Files:**
- Create: `runtime/lib/esr/tmux_process.ex`
- Create: `runtime/test/esr/tmux_process_test.exs`

- [ ] **Step 1: write integration test**

Create `runtime/test/esr/tmux_process_test.exs`:

```elixir
defmodule Esr.TmuxProcessTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  @session_name "esr-test-tmux-#{System.system_time(:millisecond)}"

  setup do
    on_exit(fn -> System.cmd("tmux", ["kill-session", "-t", @session_name]) end)
    :ok
  end

  test "starts tmux in -C mode and receives %begin/%end output markers" do
    {:ok, pid} = Esr.TmuxProcess.start_link(%{session_name: @session_name, dir: "/tmp"})
    {:ok, _os_pid} = GenServer.call(pid, :os_pid)

    # Send a simple command via the control-mode protocol
    :ok = Esr.TmuxProcess.send_command(pid, "list-windows")

    # Expect a %begin ... %end envelope back
    assert_receive {:tmux_event, {:begin, _time, _num, _flags}}, 2000
    assert_receive {:tmux_event, {:end, _time, _num, _flags}}, 2000

    GenServer.stop(pid)
  end
end
```

- [ ] **Step 2: run test**

```bash
mix test test/esr/tmux_process_test.exs --only integration
```

Expected: FAIL with module undefined.

- [ ] **Step 3: implement TmuxProcess**

Create `runtime/lib/esr/tmux_process.ex`:

```elixir
defmodule Esr.TmuxProcess do
  @moduledoc """
  Peer + OSProcess composition that owns one tmux session in control mode (`-C`).

  Control mode gives a tagged, line-protocol output stream
  (`%output`, `%begin`, `%end`, `%exit`, `%session-changed`, etc.) so
  consumers don't need to parse raw ANSI.

  See spec §3.2 and §4.1 TmuxProcess card.
  """

  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :tmux

  def start_link(args) do
    GenServer.start_link(__MODULE__.OSProcessWorker, args, name: name_for(args))
  end

  def send_command(pid, cmd) do
    GenServer.cast(pid, {:send_command, cmd})
  end

  @impl Esr.Peer.Stateful
  def init(%{session_name: _, dir: _} = args) do
    {:ok, %{session_name: args.session_name, dir: args.dir, subscribers: [args[:subscriber] || self()]}}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:tmux_event, _} = event, state) do
    Enum.each(state.subscribers, &send(&1, event))
    {:forward, [event], state}
  end

  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream({:send_keys, text}, state) do
    cmd = "send-keys -t #{state.session_name} \"#{escape(text)}\" Enter\n"
    Esr.TmuxProcess.OSProcessWorker.write_stdin(self(), cmd)
    {:forward, [], state}
  end

  def handle_downstream(_msg, state), do: {:forward, [], state}

  @impl Esr.OSProcess
  def os_cmd(state) do
    ["tmux", "-C", "new-session", "-d", "-s", state.session_name, "-c", state.dir]
  end

  @impl Esr.OSProcess
  def os_env(_state), do: []

  @impl Esr.OSProcess
  def on_os_exit(0, _state), do: {:stop, :normal}
  def on_os_exit(status, _state), do: {:stop, {:tmux_crashed, status}}

  defp escape(text), do: String.replace(text, ~S("), ~S(\"))

  defp name_for(%{session_name: n}), do: String.to_atom("esr_tmux_#{n}")
end
```

**Note:** `Esr.TmuxProcess.OSProcessWorker.write_stdin/2` is a helper that needs to be added to the OSProcessWorker macro (extend `os_process.ex` to forward stdin writes to `MuonTrap.Daemon`'s input). That extension is part of this task; include it below.

- [ ] **Step 4: extend OSProcess worker with stdin write support**

Modify `runtime/lib/esr/os_process.ex` — inside the `OSProcessWorker` `quote do` block, add:

```elixir
def write_stdin(pid, bytes), do: GenServer.cast(pid, {:write_stdin, bytes})

@impl true
def handle_cast({:write_stdin, bytes}, s) do
  MuonTrap.Daemon.send(s.daemon, bytes)
  {:noreply, s}
end
```

And handle `{:daemon_stdout, line}` to parse and forward as `:tmux_event` or similar. (Concrete parsing code for tmux `-C` line-protocol added below.)

Add to `tmux_process.ex` a pure parser:

```elixir
@doc false
def parse_event("%begin " <> rest) do
  [time, num, flags] = String.split(String.trim_trailing(rest), " ", parts: 3)
  {:begin, time, num, flags}
end

def parse_event("%end " <> rest) do
  [time, num, flags] = String.split(String.trim_trailing(rest), " ", parts: 3)
  {:end, time, num, flags}
end

def parse_event("%output " <> rest) do
  [pane_id, bytes] = String.split(String.trim_trailing(rest), " ", parts: 2)
  {:output, pane_id, bytes}
end

def parse_event("%exit" <> _), do: {:exit}

def parse_event(other), do: {:unknown, other}
```

Wire the worker's `:daemon_stdout` handler to call this parser and dispatch to the Peer's `handle_upstream({:tmux_event, event}, state)`.

- [ ] **Step 5: run test**

```bash
mix test test/esr/tmux_process_test.exs --only integration
```

Expected: PASS. If tmux isn't installed: `brew install tmux`.

- [ ] **Step 6: run full suite**

```bash
mix test
```

Expected: all green.

- [ ] **Step 7: commit**

```bash
git add runtime/lib/esr/tmux_process.ex runtime/lib/esr/os_process.ex runtime/test/esr/tmux_process_test.exs
git commit -m "feat(tmux_process): Peer + OSProcess底座 for tmux -C control mode

TmuxProcess owns one tmux session in control mode. Events (%output,
%begin, %end, %exit) are parsed into structured messages and
dispatched via Peer.Stateful upstream. send_command/2 writes commands
back to tmux's control socket.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-7: `Esr.PyProcess` implementation + JSON-line round-trip test

**Files:**
- Create: `runtime/lib/esr/py_process.ex`
- Create: `runtime/test/esr/py_process_test.exs`
- Create: `runtime/test/fixtures/py/echo_sidecar.py`

- [ ] **Step 1: create a minimal echo sidecar fixture**

Create `runtime/test/fixtures/py/echo_sidecar.py`:

```python
#!/usr/bin/env python3
"""Test fixture: echo each JSON-line request as a reply with same id."""
import json, sys

for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        req = json.loads(line)
    except json.JSONDecodeError:
        continue
    reply = {"id": req.get("id"), "kind": "reply", "payload": req.get("payload")}
    sys.stdout.write(json.dumps(reply) + "\n")
    sys.stdout.flush()
```

Make it executable: `chmod +x runtime/test/fixtures/py/echo_sidecar.py`.

- [ ] **Step 2: write integration test**

Create `runtime/test/esr/py_process_test.exs`:

```elixir
defmodule Esr.PyProcessTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  test "JSON-line round-trip with echo sidecar" do
    fixture = Path.expand("fixtures/py/echo_sidecar.py", __DIR__ |> Path.join(".."))

    {:ok, pid} =
      Esr.PyProcess.start_link(%{
        entry_point: {:script, fixture},
        subscriber: self()
      })

    :ok = Esr.PyProcess.send_request(pid, %{id: "req-1", payload: %{hello: "world"}})

    assert_receive {:py_reply, %{"id" => "req-1", "kind" => "reply", "payload" => %{"hello" => "world"}}}, 3000

    GenServer.stop(pid)
  end
end
```

- [ ] **Step 3: implement PyProcess**

Create `runtime/lib/esr/py_process.ex`:

```elixir
defmodule Esr.PyProcess do
  @moduledoc """
  Peer + OSProcess composition for Python sidecars.

  Protocol: JSON lines over stdin/stdout. Each request is a single-line
  JSON object `{"id": "...", "kind": "request", "payload": {...}}`;
  each reply is `{"id": "...", "kind": "reply", "payload": {...}}`.

  See spec §3.2 and §8.3.
  """

  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :python

  def start_link(args) do
    GenServer.start_link(__MODULE__.OSProcessWorker, args)
  end

  def send_request(pid, %{id: _} = req) do
    line = Jason.encode!(Map.put(req, :kind, "request")) <> "\n"
    __MODULE__.OSProcessWorker.write_stdin(pid, line)
  end

  @impl Esr.Peer.Stateful
  def init(args) do
    {:ok, %{entry_point: args.entry_point, subscribers: [args[:subscriber] || self()]}}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:py_reply, _} = msg, state) do
    Enum.each(state.subscribers, &send(&1, msg))
    {:forward, [msg], state}
  end

  def handle_upstream(_, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_, state), do: {:forward, [], state}

  @impl Esr.OSProcess
  def os_cmd(state) do
    case state.entry_point do
      {:module, mod} -> ["uv", "run", "python", "-m", mod]
      {:script, path} -> ["uv", "run", "python", path]
    end
  end

  @impl Esr.OSProcess
  def os_env(_), do: [{"PYTHONUNBUFFERED", "1"}]

  @impl Esr.OSProcess
  def on_os_exit(0, _state), do: {:stop, :normal}
  def on_os_exit(status, _state), do: {:stop, {:py_crashed, status}}

  @doc false
  def parse_reply_line(line) do
    case Jason.decode(line) do
      {:ok, map} -> {:py_reply, map}
      {:error, _} -> {:py_parse_error, line}
    end
  end
end
```

Wire the worker to call `parse_reply_line/1` for each stdout line and dispatch as `handle_upstream({:py_reply, parsed})`.

- [ ] **Step 4: run test**

```bash
mix test test/esr/py_process_test.exs --only integration
```

Expected: PASS.

- [ ] **Step 5: commit**

```bash
git add runtime/lib/esr/py_process.ex runtime/test/esr/py_process_test.exs runtime/test/fixtures/py/
git commit -m "feat(py_process): Peer + OSProcess底座 for Python sidecars

JSON-line protocol over stdin/stdout. Round-trip integration test
with a minimal echo sidecar fixture proves the contract.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-8: Rename old `SessionRegistry` → `SessionSocketRegistry`

**Files:**
- Rename: `runtime/lib/esr/session_registry.ex` → `runtime/lib/esr/session_socket_registry.ex`
- Rename: `runtime/test/esr/session_registry_test.exs` → `runtime/test/esr/session_socket_registry_test.exs`
- Modify: all callers (grep for `Esr.SessionRegistry`)

- [ ] **Step 1: rename files**

```bash
git mv runtime/lib/esr/session_registry.ex runtime/lib/esr/session_socket_registry.ex
git mv runtime/test/esr/session_registry_test.exs runtime/test/esr/session_socket_registry_test.exs
```

- [ ] **Step 2: update the module name inside both files**

In `session_socket_registry.ex`: `defmodule Esr.SessionRegistry do` → `defmodule Esr.SessionSocketRegistry do`. Update `@moduledoc` to reflect: "Formerly `Esr.SessionRegistry`. Manages CC WebSocket session bindings (ws_pid → chat_ids/app_ids/workspace/principal). Renamed to free `Esr.SessionRegistry` for the new yaml-compiled topology registry (see spec §2.3)."

In `session_socket_registry_test.exs`: update the `alias` and `describe` blocks.

- [ ] **Step 3: grep and replace all callers**

```bash
rg -l "Esr.SessionRegistry" | xargs sed -i '' 's/Esr\.SessionRegistry/Esr.SessionSocketRegistry/g'
```

- [ ] **Step 4: run tests**

```bash
mix test
```

Expected: all green. If references failed to update in strings (test assertions), fix them.

- [ ] **Step 5: commit**

```bash
git add -A
git commit -m "refactor(session_registry): rename to SessionSocketRegistry

Frees the name Esr.SessionRegistry for the new yaml-compiled topology
registry coming in the next task. Content unchanged; only the module
name changes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-9: New `Esr.SessionRegistry` skeleton (yaml compiler)

**Files:**
- Create: `runtime/lib/esr/session_registry.ex`
- Create: `runtime/test/esr/session_registry_test.exs`
- Create: `runtime/test/fixtures/agents/simple.yaml`

- [ ] **Step 1: write tests**

Create `runtime/test/fixtures/agents/simple.yaml`:

```yaml
agents:
  cc:
    description: "Claude Code"
    capabilities_required:
      - cap.session.create
      - cap.tmux.spawn
    pipeline:
      inbound:
        - name: feishu_chat_proxy
          impl: Esr.Peers.FeishuChatProxy
        - name: cc_process
          impl: Esr.Peers.CCProcess
      outbound:
        - cc_process
        - feishu_chat_proxy
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Peers.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"
    params:
      - name: dir
        required: true
        type: path
```

Create `runtime/test/esr/session_registry_test.exs`:

```elixir
defmodule Esr.SessionRegistryTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!({Esr.SessionRegistry, []})
    :ok
  end

  test "loads agents.yaml and exposes agent_def/1" do
    path = Path.expand("fixtures/agents/simple.yaml", __DIR__)
    :ok = Esr.SessionRegistry.load_agents(path)

    assert {:ok, agent_def} = Esr.SessionRegistry.agent_def("cc")
    assert agent_def.description == "Claude Code"
    assert "cap.session.create" in agent_def.capabilities_required
    assert length(agent_def.pipeline.inbound) == 2
  end

  test "returns error for unknown agent" do
    assert {:error, :not_found} = Esr.SessionRegistry.agent_def("nonexistent")
  end

  test "registers session and looks up by chat_thread" do
    :ok = Esr.SessionRegistry.register_session("session-1", %{chat_id: "c1", thread_id: "t1"}, %{})

    assert {:ok, "session-1", _peer_refs} =
             Esr.SessionRegistry.lookup_by_chat_thread("c1", "t1")
  end

  test "reserved field names in agents.yaml trigger WARN log" do
    path = Path.join(System.tmp_dir!(), "reserved_test.yaml")
    File.write!(path, ~S"""
    agents:
      demo:
        description: "demo"
        capabilities_required: []
        pipeline: {inbound: [], outbound: []}
        proxies: []
        params: []
        rate_limits: {}  # reserved
    """)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Esr.SessionRegistry.load_agents(path)
      end)

    assert log =~ "reserved field"
    File.rm!(path)
  end
end
```

- [ ] **Step 2: run test**

```bash
mix test test/esr/session_registry_test.exs
```

Expected: FAIL (module doesn't exist yet).

- [ ] **Step 3: implement minimal SessionRegistry**

Create `runtime/lib/esr/session_registry.ex`:

```elixir
defmodule Esr.SessionRegistry do
  @moduledoc """
  YAML-compiled topology registry + runtime mappings.

  Single source of truth for:
  - `agents.yaml` compiled agent definitions
  - `(chat_id, thread_id) → session_id` lookup
  - `(session_id, peer_name) → pid` lookup
  - yaml hot-reload

  See spec §3.3 and §3.5.
  """
  use GenServer
  require Logger

  @reserved_fields ~w(rate_limits timeout_ms allowed_principals)a

  # Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def load_agents(path), do: GenServer.call(__MODULE__, {:load_agents, path})
  def agent_def(name), do: GenServer.call(__MODULE__, {:agent_def, name})
  def register_session(session_id, chat_thread_key, peer_refs),
    do: GenServer.call(__MODULE__, {:register_session, session_id, chat_thread_key, peer_refs})
  def lookup_by_chat_thread(chat_id, thread_id),
    do: GenServer.call(__MODULE__, {:lookup_by_chat_thread, chat_id, thread_id})
  def unregister_session(session_id), do: GenServer.call(__MODULE__, {:unregister_session, session_id})

  # GenServer callbacks
  @impl true
  def init(_opts) do
    {:ok, %{agents: %{}, sessions: %{}, chat_to_session: %{}}}
  end

  @impl true
  def handle_call({:load_agents, path}, _from, state) do
    case parse_agents_file(path) do
      {:ok, agents} ->
        {:reply, :ok, %{state | agents: agents}}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:agent_def, name}, _from, state) do
    case Map.fetch(state.agents, name) do
      {:ok, def_} -> {:reply, {:ok, def_}, state}
      :error      -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:register_session, session_id, %{chat_id: c, thread_id: t} = key, refs}, _from, state) do
    state =
      state
      |> put_in([:sessions, session_id], %{key: key, refs: refs})
      |> put_in([:chat_to_session, {c, t}], session_id)

    {:reply, :ok, state}
  end

  def handle_call({:lookup_by_chat_thread, c, t}, _from, state) do
    case Map.get(state.chat_to_session, {c, t}) do
      nil -> {:reply, :not_found, state}
      sid ->
        refs = get_in(state, [:sessions, sid, :refs]) || %{}
        {:reply, {:ok, sid, refs}, state}
    end
  end

  def handle_call({:unregister_session, sid}, _from, state) do
    case Map.get(state.sessions, sid) do
      nil -> {:reply, :ok, state}
      %{key: %{chat_id: c, thread_id: t}} ->
        state =
          state
          |> update_in([:sessions], &Map.delete(&1, sid))
          |> update_in([:chat_to_session], &Map.delete(&1, {c, t}))
        {:reply, :ok, state}
    end
  end

  # Internal: yaml parse + reserved-field warning
  defp parse_agents_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- YamlElixir.read_from_string(content) do
      agents = parsed["agents"] || %{}
      agents_compiled =
        for {name, spec} <- agents, into: %{} do
          warn_if_reserved_fields(name, spec)
          {name, compile_agent(spec)}
        end
      {:ok, agents_compiled}
    end
  end

  defp warn_if_reserved_fields(name, spec) do
    for field <- @reserved_fields, Map.has_key?(spec, Atom.to_string(field)) do
      Logger.warning("agents.yaml: agent '#{name}' uses reserved field '#{field}' (not implemented; will be ignored)")
    end
  end

  defp compile_agent(spec) do
    %{
      description: spec["description"] || "",
      capabilities_required: spec["capabilities_required"] || [],
      pipeline: %{
        inbound: spec["pipeline"]["inbound"] || [],
        outbound: spec["pipeline"]["outbound"] || []
      },
      proxies: spec["proxies"] || [],
      params: spec["params"] || []
    }
  end
end
```

- [ ] **Step 4: add `yaml_elixir` dependency**

Check `runtime/mix.exs` — if `yaml_elixir` is not already listed, add `{:yaml_elixir, "~> 2.9"}`.

Run: `mix deps.get`

- [ ] **Step 5: run test**

```bash
mix test test/esr/session_registry_test.exs
```

Expected: PASS.

- [ ] **Step 6: run full suite**

```bash
mix test
```

Expected: all green.

- [ ] **Step 7: commit**

```bash
git add runtime/lib/esr/session_registry.ex runtime/test/esr/session_registry_test.exs runtime/test/fixtures/agents/ runtime/mix.exs runtime/mix.lock
git commit -m "feat(session_registry): yaml-compiled topology registry

New Esr.SessionRegistry (distinct from old SessionSocketRegistry)
compiles agents.yaml into agent definitions and holds chat_thread ↔
session_id ↔ peer_refs mappings. Reserved field names generate a WARN
log so future features (rate_limits, timeout_ms, allowed_principals)
don't get accidentally squatted.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-10: `Esr.PeerFactory`

**Files:**
- Create: `runtime/lib/esr/peer_factory.ex`
- Create: `runtime/test/esr/peer_factory_test.exs`

- [ ] **Step 1: write test**

Create `runtime/test/esr/peer_factory_test.exs`:

```elixir
defmodule Esr.PeerFactoryTest do
  use ExUnit.Case, async: false

  defmodule TestPeer do
    use Esr.Peer.Stateful
    def init(args), do: {:ok, args}
    def handle_upstream(_, s), do: {:forward, [], s}
    def handle_downstream(_, s), do: {:forward, [], s}
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def handle_call(_, _, s), do: {:reply, :ok, s}
  end

  setup do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: TestSup)
    %{sup: TestSup}
  end

  test "spawn_peer starts a child under the specified supervisor", %{sup: sup} do
    assert {:ok, pid} =
             Esr.PeerFactory.spawn_peer(sup, TestPeer, %{name: "p1"}, [], %{})

    assert Process.alive?(pid)
  end

  test "spawn_peer rejects unknown peer impl", %{sup: sup} do
    assert {:error, _} =
             Esr.PeerFactory.spawn_peer(sup, NonExistentMod, %{}, [], %{})
  end

  test "PeerFactory.__info__(:functions) matches the declared public surface" do
    expected = [
      {:spawn_peer, 5},
      {:terminate_peer, 2},
      {:restart_peer, 2}
    ]

    actual =
      Esr.PeerFactory.__info__(:functions)
      |> Enum.filter(fn {k, _} -> not String.starts_with?(Atom.to_string(k), "__") end)

    for fn_arity <- expected do
      assert fn_arity in actual
    end
  end
end
```

- [ ] **Step 2: run test**

```bash
mix test test/esr/peer_factory_test.exs
```

Expected: FAIL.

- [ ] **Step 3: implement PeerFactory**

Create `runtime/lib/esr/peer_factory.ex`:

```elixir
defmodule Esr.PeerFactory do
  @moduledoc """
  Creation mechanics for Peers. Thin wrapper over `DynamicSupervisor.start_child`.

  **Hard rule:** this module MUST NOT contain routing/lookup/decision logic.
  Its public surface is exactly three functions: `spawn_peer/5`,
  `terminate_peer/2`, `restart_peer/2`. Review rejects additions.

  See spec §3.3 and §6 Risk A.
  """
  require Logger

  @spec spawn_peer(sup :: term(), mod :: module(), args :: map(), neighbors :: list(), ctx :: map()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_peer(sup, mod, args, neighbors, ctx) do
    :telemetry.execute([:esr, :peer_factory, :spawn], %{}, %{mod: mod, ctx: ctx})

    if Code.ensure_loaded?(mod) do
      init_args = Map.merge(args, %{neighbors: neighbors, proxy_ctx: ctx})
      DynamicSupervisor.start_child(sup, {mod, init_args})
    else
      {:error, {:unknown_impl, mod}}
    end
  end

  @spec terminate_peer(sup :: term(), pid :: pid()) :: :ok | {:error, term()}
  def terminate_peer(sup, pid) do
    DynamicSupervisor.terminate_child(sup, pid)
  end

  @spec restart_peer(sup :: term(), spec :: term()) :: {:ok, pid()} | {:error, term()}
  def restart_peer(sup, spec) do
    DynamicSupervisor.start_child(sup, spec)
  end
end
```

- [ ] **Step 4: run test**

```bash
mix test test/esr/peer_factory_test.exs
```

Expected: PASS.

- [ ] **Step 5: commit**

```bash
git add runtime/lib/esr/peer_factory.ex runtime/test/esr/peer_factory_test.exs
git commit -m "feat(peer_factory): creation mechanics wrapper

Thin wrapper over DynamicSupervisor.start_child with telemetry and
arg validation. Strict public surface: spawn_peer/5, terminate_peer/2,
restart_peer/2. Enforcement test verifies the surface does not drift.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-11: `Esr.PeerPool` with default max=128

**Files:**
- Create: `runtime/lib/esr/peer_pool.ex`
- Create: `runtime/test/esr/peer_pool_test.exs`

- [ ] **Step 1: write tests covering acquire/release + exhaustion**

Create `runtime/test/esr/peer_pool_test.exs`:

```elixir
defmodule Esr.PeerPoolTest do
  use ExUnit.Case, async: false

  defmodule DummyWorker do
    use GenServer
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def init(args), do: {:ok, args}
    def handle_call(:ping, _, s), do: {:reply, :pong, s}
  end

  test "default max_workers is 128" do
    assert Esr.PeerPool.default_max_workers() == 128
  end

  test "acquire returns a worker pid and release puts it back" do
    {:ok, pool} = Esr.PeerPool.start_link(name: :test_pool_1, worker: DummyWorker, max: 4)

    {:ok, w1} = Esr.PeerPool.acquire(pool)
    assert GenServer.call(w1, :ping) == :pong

    :ok = Esr.PeerPool.release(pool, w1)
    # Acquire again, may or may not be same worker
    {:ok, w2} = Esr.PeerPool.acquire(pool)
    assert is_pid(w2)
  end

  test "pool exhaustion returns :pool_exhausted" do
    {:ok, pool} = Esr.PeerPool.start_link(name: :test_pool_2, worker: DummyWorker, max: 2)

    {:ok, _} = Esr.PeerPool.acquire(pool)
    {:ok, _} = Esr.PeerPool.acquire(pool)
    assert {:error, :pool_exhausted} = Esr.PeerPool.acquire(pool, timeout: 100)
  end
end
```

- [ ] **Step 2: run test**

Expected: FAIL.

- [ ] **Step 3: implement PeerPool**

Create `runtime/lib/esr/peer_pool.ex`:

```elixir
defmodule Esr.PeerPool do
  @moduledoc """
  Pool of interchangeable Peer.Stateful workers.

  Default `max_workers: 128` (spec D16). Optional `pools.yaml` can override
  per-pool limits; unspecified pools inherit the default.

  See spec §3.4.
  """
  use GenServer

  @default_max 128

  def default_max_workers, do: @default_max

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def acquire(pool, opts \\ []), do: GenServer.call(pool, {:acquire, opts}, opts[:timeout] || 5000)
  def release(pool, pid), do: GenServer.cast(pool, {:release, pid})

  @impl true
  def init(opts) do
    max = opts[:max] || @default_max
    worker_mod = Keyword.fetch!(opts, :worker)
    {:ok, %{max: max, worker_mod: worker_mod, workers: %{}, available: :queue.new(), waiters: :queue.new()}}
  end

  @impl true
  def handle_call({:acquire, opts}, from, state) do
    case :queue.out(state.available) do
      {{:value, pid}, q} -> {:reply, {:ok, pid}, %{state | available: q}}
      {:empty, _} ->
        if map_size(state.workers) < state.max do
          {:ok, pid} = state.worker_mod.start_link([])
          workers = Map.put(state.workers, pid, true)
          Process.monitor(pid)
          {:reply, {:ok, pid}, %{state | workers: workers}}
        else
          timeout = opts[:timeout] || 5000
          if timeout == 0 do
            {:reply, {:error, :pool_exhausted}, state}
          else
            Process.send_after(self(), {:waiter_timeout, from}, timeout)
            {:noreply, %{state | waiters: :queue.in({from, :os.system_time(:millisecond) + timeout}, state.waiters)}}
          end
        end
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    case :queue.out(state.waiters) do
      {{:value, {from, _deadline}}, q} ->
        GenServer.reply(from, {:ok, pid})
        {:noreply, %{state | waiters: q}}
      {:empty, _} ->
        {:noreply, %{state | available: :queue.in(pid, state.available)}}
    end
  end

  @impl true
  def handle_info({:waiter_timeout, from}, state) do
    # Reply with exhaustion if still waiting
    new_waiters = :queue.filter(fn {f, _} -> f != from end, state.waiters)
    if :queue.len(new_waiters) < :queue.len(state.waiters) do
      GenServer.reply(from, {:error, :pool_exhausted})
    end
    {:noreply, %{state | waiters: new_waiters}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    workers = Map.delete(state.workers, pid)
    available = :queue.filter(fn p -> p != pid end, state.available)
    {:noreply, %{state | workers: workers, available: available}}
  end
end
```

- [ ] **Step 4: run test**

```bash
mix test test/esr/peer_pool_test.exs
```

Expected: PASS.

- [ ] **Step 5: commit**

```bash
git add runtime/lib/esr/peer_pool.ex runtime/test/esr/peer_pool_test.exs
git commit -m "feat(peer_pool): DynamicSupervisor-backed pool with default max=128

Workers are interchangeable; acquire returns any available worker
(or spawns a new one if under max), release puts it back. Exhaustion
returns {:error, :pool_exhausted} after the configured timeout.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-12: Add new control-plane modules to application.ex

**Files:**
- Modify: `runtime/lib/esr/application.ex`

- [ ] **Step 1: confirm current supervision tree**

Read `runtime/lib/esr/application.ex`. Note the existing children list.

- [ ] **Step 2: add new children**

At an appropriate position in the children list (before any dependent services), add:

```elixir
{Esr.SessionRegistry, []},
# Esr.SessionSocketRegistry retains its existing entry (it was already in the tree as Esr.SessionRegistry; adjust the name)
```

Update the `Esr.SessionRegistry` entry (if it exists referring to the old one) to `Esr.SessionSocketRegistry`, since the rename happened in P1-8.

- [ ] **Step 3: run full tests + start the app**

```bash
mix test
```

And manually:
```bash
iex -S mix
# inside iex:
# Process.whereis(Esr.SessionRegistry)     # should return a pid
# Process.whereis(Esr.SessionSocketRegistry) # should return a pid
```

Expected: both pids returned, no crash.

- [ ] **Step 4: commit**

```bash
git add runtime/lib/esr/application.ex
git commit -m "chore(app): wire Esr.SessionRegistry and renamed SessionSocketRegistry

Both the new SessionRegistry (yaml compiler) and the renamed
SessionSocketRegistry (WS bindings) are now started at boot. No
downstream callers use the new one yet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task P1-13: Self-review + PR open

- [ ] **Step 1: run all PR-1 acceptance gates**

```bash
cd runtime
mix test
mix test --only integration
```

Expected: all green.

- [ ] **Step 2: verify decommissioning list**

None yet in PR-1 (PR-1 is purely additive).

- [ ] **Step 3: push branch**

```bash
git push origin feature/peer-session-refactor
```

- [ ] **Step 4: open PR-1 draft**

```bash
gh pr create --draft --title "feat(runtime): Peer behaviours + OSProcess底座 + SessionRegistry (PR-1)" --body "$(cat <<'EOF'
## Summary

- Adds `Esr.Peer` behaviour with `Peer.Proxy` (stateless, compile-time callback-ban) and `Peer.Stateful` (with init/handle_upstream/handle_downstream).
- Adds `Esr.OSProcess` behaviour with `Esr.TmuxProcess` (tmux -C control mode) and `Esr.PyProcess` (uv run python -m) implementations via MuonTrap.
- Adds `Esr.PeerFactory` (creation wrapper, strict public surface).
- Adds `Esr.PeerPool` (default max=128, pool-acquire semantics).
- Renames `Esr.SessionRegistry` → `Esr.SessionSocketRegistry`.
- Creates new `Esr.SessionRegistry` (yaml compiler + mapping registry).
- Wires both into application.ex.
- No production code uses the new modules yet (fully additive).

Implements PR-1 of the Peer/Session Refactor. See `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` and `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`.

## Test plan

- [x] `mix test` all green
- [x] OSProcess cleanup: kill peer → OS process dies ≤10s
- [x] TmuxProcess control-mode: receives `%begin`/`%end`
- [x] PyProcess JSON-line round-trip
- [x] Peer.Proxy compile-error test (handle_call/handle_cast rejected)
- [x] SessionRegistry agents.yaml parse + reserved-field WARN
- [x] PeerFactory surface check
- [x] PeerPool exhaustion returns :pool_exhausted

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: review diff**

Verify the PR description matches what's in the diff.

**PR-1 ready for review.**

---

# PR-2: Feishu Chain + AdminSession (outline)

**Goal:** Move all Feishu-related logic from the current `peer_server.ex` amalgam into typed Peers under AdminSession + user Sessions. After this PR, the Feishu path uses the new peer chain end-to-end.

**Prereq:** PR-1 merged to `feature/peer-session-refactor`.

**Acceptance gates** (spec §10.5):
- AdminSession boot test: supervision tree matches §4
- FeishuAppAdapter inbound: fake WS frame → envelope decoded → correct FeishuChatProxy pid receives message
- FeishuChatProxy slash detection: `/` prefix → SlashHandler; no `/` → downstream
- FeishuAppProxy capability check
- Session supervisor boot test: tree matches `agents.yaml`
- N=2 concurrent sessions: no cross-contamination
- E2E smoke: `/new-session --agent cc --dir /tmp/test` via fake Feishu → Session created
- `Esr.AdapterHub.Registry` and `Esr.AdapterHub.Supervisor` deleted

### Task outlines

| Task | Purpose | Key files |
|---|---|---|
| P2-1 | Create `Esr.AdminSession` supervisor + `Esr.AdminSessionProcess` | `admin_session.ex`, `admin_session_process.ex`, test |
| P2-2 | Create `Esr.Peers.FeishuAppAdapter` (Peer.Stateful; owns WS) | `peers/feishu_app_adapter.ex`, test |
| P2-3 | Create `Esr.Peers.FeishuChatProxy` (Peer.Stateful; slash detection) | `peers/feishu_chat_proxy.ex`, test |
| P2-4 | Create `Esr.Peers.FeishuAppProxy` (Peer.Proxy + capability check) | `peers/feishu_app_proxy.ex`, test |
| P2-5 | Create `Esr.Peers.SlashHandler` (Peer.Stateful; channel-agnostic) | `peers/slash_handler.ex`, test |
| P2-6 | Create `Esr.Session` supervisor module + `Esr.SessionProcess` | `session.ex`, `session_process.ex`, test |
| P2-7 | Create `Esr.SessionsSupervisor` (DynamicSupervisor, max_children=128) | `sessions_supervisor.ex`, test |
| P2-8 | Agents.yaml fixture with minimal `cc` agent declaration | `${ESRD_HOME}/default/agents.yaml` (dev), test fixture |
| P2-9 | Update `application.ex` to start AdminSession + SessionsSupervisor | `application.ex` |
| P2-10 | Feature flag `USE_NEW_PEER_CHAIN` in Feishu webhook handler | `esr_web/feishu_controller.ex` (or equivalent) |
| P2-11 | Route inbound Feishu frames through new FeishuAppAdapter when flag is on | as above |
| P2-12 | Integration test: N=2 sessions | `test/esr/integration/n2_sessions_test.exs` |
| P2-13 | E2E smoke: `/new-session --agent cc --dir /tmp/test` via fake Feishu | `test/esr/integration/new_session_smoke_test.exs` |
| P2-14 | Flip feature flag to ON by default; keep old code as fallback | config |
| P2-15 | Remove old Feishu handling from `peer_server.ex` | `peer_server.ex` |
| P2-16 | Delete `Esr.AdapterHub.Registry` + `Esr.AdapterHub.Supervisor` | file deletions |
| P2-17 | Remove feature flag (now that new path is sole path) | config cleanup |
| P2-18 | Open PR-2 | `gh pr create` |

**When PR-1 merges, expand each P2-N into bite-sized TDD steps matching the API shapes from PR-1.**

---

# PR-3: CC Chain + SessionRouter + Topology Removal (outline)

**Goal:** Migrate CC/tmux path to new peers; introduce real SessionRouter (control plane); delete Topology module; delete misplaced `Esr.Routing.SlashHandler`; require `agent` field in `session_new`.

**Prereq:** PR-2 merged.

**Acceptance gates** (spec §10.5):
- CCProcess, CCProxy, TmuxProcess (with MuonTrap) all functional
- SessionRouter control-plane boundary test: data-plane messages rejected
- PubSub broadcast audit clean
- Full E2E: Feishu inbound → tmux stdin → tmux output → Feishu outbound
- N=2 tmux independent
- OS cleanup regression: `kill -9` esrd → all tmux die in 10s
- `session_new` requires `agent` field
- Topology module files deleted

### Task outlines

| Task | Purpose | Key files |
|---|---|---|
| P3-1 | Create `Esr.Peers.CCProxy` (Peer.Proxy) | `peers/cc_proxy.ex`, test |
| P3-2 | Create `Esr.Peers.CCProcess` (Peer.Stateful) | `peers/cc_process.ex`, test |
| P3-3 | Create `Esr.Peers.TmuxProcess` (Peer.Stateful + OSProcess, control-mode) | `peers/tmux_process.ex`, test |
| P3-4 | Create `Esr.SessionRouter` (control plane) | `session_router.ex`, test |
| P3-5 | Control-plane boundary test: reject data-plane messages | test |
| P3-6 | Integrate CC peers into `cc` agent in `agents.yaml` | yaml update |
| P3-7 | Wire SessionRouter to respond to `:new_chat_thread` event from FeishuAppAdapter | cross-module |
| P3-8 | Update `Esr.Admin.Commands.Session.New` to require `agent` field | `session/new.ex` |
| P3-9 | Update `Esr.Admin.Commands.Session.End` to tear down new Session supervisor tree | `session/end.ex` |
| P3-10 | Full E2E test: Feishu → tmux → Feishu roundtrip | `test/esr/integration/cc_e2e_test.exs` |
| P3-11 | N=2 concurrent tmux test | `test/esr/integration/n2_tmux_test.exs` |
| P3-12 | OS cleanup regression: `mix test.e2e.os_cleanup` task + test | `mix.exs` tasks + test |
| P3-13 | Delete `Esr.Topology.Registry`, `.Instantiator`, `.Supervisor` | file deletions |
| P3-14 | Delete `Esr.Routing.SlashHandler` (renamed misplaced router from PR-0) | file deletion |
| P3-15 | PubSub audit: grep for free broadcasts; convert to neighbor-ref `send/cast` | manual sweep + test |
| P3-16 | Delete old CC/tmux code from `peer_server.ex` | `peer_server.ex` |
| P3-17 | Open PR-3 | `gh pr create` |

**When PR-2 merges, expand each P3-N into bite-sized steps.**

---

# PR-4a: Voice-Gateway Split (outline)

**Goal:** Split `py/voice_gateway/` into three Python sidecars (`voice-asr`, `voice-tts`, `voice-e2e`); add Elixir peer wrappers; introduce `cc-voice` and `voice-e2e` agents.

**Prereq:** PR-2 merged (PR-3 can run in parallel).

**Acceptance gates** (spec §10.5):
- Each sidecar: Python unit tests pass
- Elixir peer unit tests (VoiceASR/TTS/E2E)
- VoiceASRPool/VoiceTTSPool acquire/release/exhaustion
- E2E: `/new-session --agent cc-voice --dir /tmp/test` with fixture audio
- E2E: `/new-session --agent voice-e2e` with fixture audio
- `py/voice_gateway/` deleted

### Task outlines

| Task | Purpose | Key files |
|---|---|---|
| P4a-1 | Create `py/voice_asr/` package (pyproject.toml, main.py) | Python |
| P4a-2 | Create `py/voice_tts/` package | Python |
| P4a-3 | Create `py/voice_e2e/` package | Python |
| P4a-4 | JSON-line protocol spec + test fixtures | shared fixture |
| P4a-5 | `Esr.Peers.VoiceASR` + proxy | `peers/voice_asr.ex`, `peers/voice_asr_proxy.ex`, test |
| P4a-6 | `Esr.Peers.VoiceTTS` + proxy | same pattern |
| P4a-7 | `Esr.Peers.VoiceE2E` | `peers/voice_e2e.ex`, test |
| P4a-8 | `Esr.VoiceASRPoolSupervisor` + `Esr.VoiceTTSPoolSupervisor` under AdminSession | `admin_session.ex` update |
| P4a-9 | Add `cc-voice` and `voice-e2e` to `agents.yaml` | yaml |
| P4a-10 | E2E: `/new-session --agent cc-voice` | integration test |
| P4a-11 | E2E: `/new-session --agent voice-e2e` | integration test |
| P4a-12 | Delete `py/voice_gateway/` | file deletion |
| P4a-13 | Open PR-4a | `gh pr create` |

---

# PR-4b: adapter_runner Split (outline)

**Goal:** Split `py/src/esr/ipc/adapter_runner.py` into per-adapter-type sidecars.

**Prereq:** PR-2 merged.

**Acceptance gates**:
- Each split sidecar: Python unit tests pass
- Existing Feishu + CC integration tests pass unchanged (regression)
- Monolithic `adapter_runner.py` deleted

### Task outlines

| Task | Purpose | Key files |
|---|---|---|
| P4b-1 | Create `py/feishu_adapter_runner/` package | Python |
| P4b-2 | Create `py/cc_adapter_runner/` package | Python |
| P4b-3 | Create `py/generic_adapter_runner/` (catch-all) | Python |
| P4b-4 | Migrate Feishu-specific code from monolithic runner | Python |
| P4b-5 | Migrate CC-specific code from monolithic runner | Python |
| P4b-6 | Update Elixir callers to target split sidecars (via PyProcess底座) | peers/ updates |
| P4b-7 | Run regression test suite | full `mix test` |
| P4b-8 | Delete `py/src/esr/ipc/adapter_runner.py` | file deletion |
| P4b-9 | Open PR-4b | `gh pr create` |

---

# PR-5: Cleanup + Docs (outline)

**Goal:** Remove transitional code, update architecture doc, measure perf regression.

**Prereq:** PR-3, PR-4a, PR-4b all merged.

**Acceptance gates**:
- `rg "USE_NEW_PEER_CHAIN"` returns zero matches
- `docs/architecture.md` updated with new module tree
- Full regression: `mix test` + `mix test.e2e.agents` + `mix test.e2e.os_cleanup` green
- Perf: Feishu webhook → tmux stdin p50/p99 within 20% of pre-refactor baseline

### Task outlines

| Task | Purpose | Key files |
|---|---|---|
| P5-1 | Remove all feature flags (`USE_NEW_PEER_CHAIN`, etc.) | config + grep sweep |
| P5-2 | Remove transitional fallback code identified during PR-2/PR-3 | various |
| P5-3 | Regenerate `docs/architecture.md` with new supervision tree | docs |
| P5-4 | Capture baseline perf from PR-0 (retrospective) and compare | perf harness |
| P5-5 | Fix any perf regression > 20% OR document as acceptable | TBD per measurement |
| P5-6 | Full regression suite run | CI |
| P5-7 | Open PR-5 | `gh pr create` |
| P5-8 | Merge PR-5 | closing the refactor |

---

## Plan Self-Review

**1. Spec coverage check:**
- §1 Background & Scope ✅ covered by plan's overview + PR dependencies
- §1.8 Decisions Log ✅ all 21 decisions traceable to specific PR tasks
- §2 Gap Analysis ✅ every component listed has a migration or decommissioning task
- §3 Target Architecture ✅ every module in §4 has a creation task
- §3.5 Agent definitions ✅ P2-8 creates agents.yaml; P3-6 wires CC; P4a-9 adds voice agents
- §4 Module tree ✅ every module mapped to PR-1/PR-2/PR-3/PR-4a
- §5 Data flows ✅ integration tests P2-13, P3-10 exercise inbound+outbound
- §6 Drift risk mitigations ✅ Risk A (PeerFactory surface) in P1-10; Risk B (Proxy compile) in P1-3; Risk C (SessionRegistry single source) in P1-9; Risk D (N>1 tests) in P2-12, P3-11; Risk E (SessionRouter boundary) in P3-5; Risk F (AdminSession boot) in P2-1
- §7 OTP patterns ✅ one_for_all in P2-6 (Session supervisor); DynamicSupervisor caps in P2-7
- §8 Python split (S3) ✅ PR-4a + PR-4b
- §10.5 Per-PR gates ✅ each PR's acceptance gates list matches spec

**2. Placeholder scan:**
- No "TBD", "implement later", "fill in details" in PR-0 or PR-1 detailed tasks.
- PR-2..PR-5 outlines state file paths and acceptance criteria concretely; bite-sized steps are explicitly deferred to "when PR-N-1 merges". This is the B approach agreed with user, not a placeholder evasion.

**3. Type consistency:**
- `Peer.Stateful` callbacks (`init/1`, `handle_upstream/2`, `handle_downstream/2`) are consistent from P1-2 through all peer implementations.
- `OSProcess` callbacks (`os_cmd/1`, `os_env/1`, `on_os_exit/2`) consistent from P1-5 → P1-6 → P1-7 → later peers.
- `PeerFactory.spawn_peer/5` signature consistent from P1-10 onward.
- `SessionRegistry.lookup_by_chat_thread/2` signature consistent from P1-9 → PR-2 FeishuAppAdapter consumer.

Plan is internally consistent.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`.**

**Recommended approach: Subagent-Driven Execution**
- Dispatch fresh subagent per task
- Two-stage review between tasks
- Per-PR expand outline → bite-sized steps before starting each new PR

**Alternative: Inline execution**
- Batch tasks with checkpoints
- All work in this session
- Slower feedback loop but single-session context

Proceeding with subagent-driven execution is recommended for this refactor given scope (70+ tasks) and duration (14-21 days).
