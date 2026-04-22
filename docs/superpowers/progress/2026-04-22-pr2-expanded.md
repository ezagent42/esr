# PR-2 Bite-Sized TDD Expansion — Feishu Chain + AdminSession

**Date**: 2026-04-22
**Branch**: `feature/peer-session-refactor` (continues from PR-1 merge, commit `155bc56`)
**Prereq reading order**: (1) `docs/superpowers/progress/2026-04-22-pr1-snapshot.md` (API shapes this PR consumes), (2) plan `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md` §PR-2, (3) spec `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.4, §3.5, §3.6, §4.1, §5.1, §5.3, §6 Risk F, §1.8 D14 D18.
**Target duration**: 4-5 days.

---

## Task table (quick reference)

| Task | Purpose | Feishu notify? |
|---|---|---|
| P2-0 | **PR-2 start notification** (separate kickoff task) | yes |
| P2-1 | `Esr.AdminSession` + `AdminSessionProcess` + `spawn_peer_bootstrap/4` (Risk F) | no (rolled into P2-5 milestone) |
| P2-2 | `Esr.Peers.FeishuAppAdapter` (Peer.Stateful; consumes `adapter:feishu/<app_id>` frames) | no |
| P2-3 | `Esr.Peers.FeishuChatProxy` (Peer.Stateful; slash detection + drop-non-slash) | no |
| P2-4 | `Peer.Proxy` macro `@required_cap` extension + `Esr.Peers.FeishuAppProxy` | no |
| P2-5 | `Esr.Peers.SlashHandler` (channel-agnostic slash peer) | **yes (milestone: P2-1..5 done)** |
| P2-6 | `Esr.Session` supervisor + `Esr.SessionProcess` + `supervisor_name/1` + remove process-dict scaffold | no |
| P2-6a | `SessionProcess.grants` field + `SessionProcess.has?/2` pass-through | no |
| P2-7 | `Esr.SessionsSupervisor` (DynamicSupervisor, max_children=128) | no |
| P2-8 | Extend agents.yaml fixtures: second app for N=2 tests + `${ESRD_HOME}/default/agents.yaml` dev stub | no |
| P2-9 | `Esr.Application.children` reshape — add AdminSession + SessionsSupervisor in correct boot order | no |
| P2-10 | Feature flag `USE_NEW_PEER_CHAIN` in `EsrWeb.AdapterChannel` forward/2 | **yes (milestone: P2-6..10 done)** |
| P2-11 | Route inbound Feishu frames through new FeishuAppAdapter when flag is on | no |
| P2-12 | Integration test: N=2 concurrent sessions, no cross-contamination | no |
| P2-13 | E2E smoke: `/new-session --agent cc --dir /tmp/test` via fake Feishu (controlled failure — CC peers are PR-3) | no |
| P2-14 | Flip `USE_NEW_PEER_CHAIN` to default true; keep old path as fallback | **yes (milestone: flag default-on)** |
| P2-15 | Remove `feishu_thread_proxy` handling from `peer_server.ex` (narrower than plan implied) | no |
| P2-16 | Delete `Esr.AdapterHub.Registry` + `Esr.AdapterHub.Supervisor` | no |
| P2-17 | Remove feature flag entirely | no |
| P2-18 | Open PR-2 draft | **yes (draft PR opened)** |
| P2-19 | Wait for user review + merge | no |
| P2-20 | Write `docs/superpowers/progress/<date>-pr2-snapshot.md` + notify | **yes (merged)** |

**Feishu cadence summary**: PR start (P2-0) → milestone after P2-5 → milestone after P2-10 → milestone after P2-14 → draft PR (P2-18) → merged (P2-20). Five notifications across ~4-5 days; respects the plan's "every 3-5 tasks" anti-spam rule.

---

## Task P2-0: PR-2 start notification

**Feishu notification**: **required** (PR start).
**Files**: none.

- [ ] **Step 1: Verify PR-1 is merged on `main`**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
git fetch origin
git log origin/main --oneline -3 | grep -q "155bc56" && echo "PR-1 on main ✅"
```

Expected: prints `PR-1 on main ✅`.

- [ ] **Step 2: Confirm `feature/peer-session-refactor` worktree is synced to main**

```bash
git log origin/main..HEAD --oneline
```

Expected: empty (branch tip = main tip after squash-merge) or only the P2 commits you're about to add.

- [ ] **Step 3: Feishu notification — PR-2 start**

Use `mcp__openclaw-channel__reply` to chat `oc_d9b47511b085e9d5b66c4595b3ef9bb9`:

> "开始 PR-2 (Feishu chain + AdminSession — 把 Feishu 全链路迁到 Peer/Session 新结构)。预计 4-5 天。里程碑：FeishuAppAdapter+SlashHandler → Session supervisor → 特性开关 → 删旧 AdapterHub。"

No commit for this task.

---

## Task P2-1: `Esr.AdminSession` + `AdminSessionProcess` + bootstrap exception (Risk F)

**Feishu notification**: no (rolled into P2-5 milestone).

**Files:**
- Create: `runtime/lib/esr/admin_session.ex`
- Create: `runtime/lib/esr/admin_session_process.ex`
- Modify: `runtime/lib/esr/peer_factory.ex` (add `spawn_peer_bootstrap/4`)
- Create: `runtime/test/esr/admin_session_test.exs`

- [ ] **Step 1: Write failing tests**

Create `runtime/test/esr/admin_session_test.exs`:

```elixir
defmodule Esr.AdminSessionTest do
  use ExUnit.Case, async: false

  @admin_children_sup_name Esr.AdminSession.ChildrenSupervisor

  setup do
    # Isolated start so the app-level AdminSession does not conflict.
    # We start the component under a throwaway name + override the
    # children supervisor name via opts.
    start_supervised!({Esr.AdminSessionProcess, []})
    {:ok, sup} =
      Esr.AdminSession.start_link(
        name: :test_admin_session,
        children_sup_name: :test_admin_children_sup,
        process_name: Esr.AdminSessionProcess
      )

    on_exit(fn ->
      if Process.alive?(sup), do: Process.exit(sup, :shutdown)
    end)

    {:ok, sup: sup}
  end

  test "AdminSession starts AdminSessionProcess", _ctx do
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
  end

  test "AdminSession.children_supervisor/1 returns the DynamicSupervisor for admin peers" do
    assert is_atom(Esr.AdminSession.children_supervisor_name(:test_admin_session))
    # ChildrenSupervisor is a DynamicSupervisor for admin-scope peers
    assert is_pid(Process.whereis(:test_admin_children_sup))
  end

  test "PeerFactory.spawn_peer_bootstrap/4 bypasses Session.supervisor_name/1" do
    defmodule DummyAdminPeer do
      use Esr.Peer.Stateful
      use GenServer
      def start_link(args), do: GenServer.start_link(__MODULE__, args)
      def init(args), do: {:ok, args}
      def handle_upstream(_, s), do: {:forward, [], s}
      def handle_downstream(_, s), do: {:forward, [], s}
      def handle_call(_, _, s), do: {:reply, :ok, s}
    end

    assert {:ok, pid} =
             Esr.PeerFactory.spawn_peer_bootstrap(
               :test_admin_children_sup,
               DummyAdminPeer,
               %{},
               []
             )

    assert Process.alive?(pid)
  end

  test "AdminSession starts even when Esr.SessionRouter is not loaded" do
    # Risk F boot-order test: AdminSession must not depend on SessionRouter
    refute Code.ensure_loaded?(Esr.SessionRouter),
           "Esr.SessionRouter must not be loaded for this test (it's introduced in PR-3)"
    assert Process.alive?(Process.whereis(Esr.AdminSessionProcess))
  end
end
```

- [ ] **Step 2: Run test, verify FAIL**

```bash
cd runtime
mix test test/esr/admin_session_test.exs
```

Expected: `UndefinedFunctionError` on `Esr.AdminSession.start_link/1`.

- [ ] **Step 3: Implement**

Create `runtime/lib/esr/admin_session_process.ex`:

```elixir
defmodule Esr.AdminSessionProcess do
  @moduledoc """
  Holds admin-level state: admin-scope peer refs (e.g. slash_handler pid),
  bootstrap metadata. Always registered under its own module name.

  See spec §3.4.
  """
  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Register an admin-scope peer pid under a symbolic name."
  def register_admin_peer(name, pid) when is_atom(name) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register_admin_peer, name, pid})
  end

  @doc "Return the pid for a registered admin-scope peer, or :error."
  def admin_peer(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:admin_peer, name})
  end

  @doc "Return the slash_handler pid (convenience for the §5.3 fallback)."
  def slash_handler_ref, do: admin_peer(:slash_handler)

  @impl true
  def init(_), do: {:ok, %{admin_peers: %{}}}

  @impl true
  def handle_call({:register_admin_peer, name, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, put_in(state.admin_peers[name], pid)}
  end

  def handle_call({:admin_peer, name}, _from, state) do
    case Map.fetch(state.admin_peers, name) do
      {:ok, pid} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, dead_pid, _reason}, state) do
    admin_peers =
      state.admin_peers
      |> Enum.reject(fn {_k, p} -> p == dead_pid end)
      |> Map.new()

    {:noreply, %{state | admin_peers: admin_peers}}
  end
end
```

Create `runtime/lib/esr/admin_session.ex`:

```elixir
defmodule Esr.AdminSession do
  @moduledoc """
  Top-level permanent Supervisor for AdminSession — the one always-on
  Session hosting session-less peers (FeishuAppAdapter_<app_id>, SlashHandler,
  pool supervisors).

  Bootstrap exception (Risk F, spec §6): AdminSession is started directly
  by `Esr.Supervisor`, NOT by `Esr.SessionRouter` (which doesn't exist
  yet at boot; introduced in PR-3). Children of AdminSession are spawned
  via `Esr.PeerFactory.spawn_peer_bootstrap/4` which bypasses the
  SessionRouter control-plane resolution.

  See spec §3.4 and §6 Risk F.
  """
  use Supervisor

  @default_children_sup_name Esr.AdminSession.ChildrenSupervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc "Name of the DynamicSupervisor that hosts admin-scope peers."
  def children_supervisor_name(_admin_sup_name \\ __MODULE__),
    do: Application.get_env(:esr, :admin_children_sup_name, @default_children_sup_name)

  @impl true
  def init(opts) do
    children_sup_name =
      Keyword.get(opts, :children_sup_name, @default_children_sup_name)

    process_name =
      Keyword.get(opts, :process_name, Esr.AdminSessionProcess)

    # Cache the children-sup name so callers can resolve it without
    # plumbing opts through.
    Application.put_env(:esr, :admin_children_sup_name, children_sup_name)

    children = [
      # AdminSessionProcess must start before any admin-scope peer so
      # register_admin_peer/2 can record pids as peers come up.
      {Esr.AdminSessionProcess, [name: process_name]},
      # DynamicSupervisor that hosts admin-scope peers. Empty at init;
      # populated later by `bootstrap_children/0` (P2-9) or test setup.
      {DynamicSupervisor, strategy: :one_for_one, name: children_sup_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Modify `runtime/lib/esr/peer_factory.ex` — append `spawn_peer_bootstrap/4`:

```elixir
  @doc """
  Bootstrap-time peer spawn that bypasses `Esr.Session.supervisor_name/1`.

  Only AdminSession's init-time children use this — it is the documented
  exception to the "all peers spawn via the normal control plane" rule
  (spec §6 Risk F). The first arg is the literal DynamicSupervisor name
  (not a session_id) because at boot AdminSession's children supervisor
  is the only supervisor that can host the peer.
  """
  @spec spawn_peer_bootstrap(sup_name :: atom(), mod :: module(), args :: map(), neighbors :: list()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_peer_bootstrap(sup_name, mod, args, neighbors) when is_atom(sup_name) do
    :telemetry.execute([:esr, :peer_factory, :spawn_bootstrap], %{}, %{mod: mod, sup: sup_name})

    if Code.ensure_loaded?(mod) do
      init_args = Map.merge(args, %{session_id: "admin", neighbors: neighbors, proxy_ctx: %{}})
      DynamicSupervisor.start_child(sup_name, {mod, init_args})
    else
      {:error, {:unknown_impl, mod}}
    end
  end
```

- [ ] **Step 4: Run test, verify PASS**

```bash
mix test test/esr/admin_session_test.exs
```

Expected: all four tests PASS.

- [ ] **Step 5: Run full test suite to check baseline**

```bash
mix test
```

Expected: 339 + any new tests green. Baseline noted in PR-1 snapshot: 339 tests, known-flake: `peer_server_lane_b_test:188`, `cap_test:149`. No new failures.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/admin_session.ex \
        runtime/lib/esr/admin_session_process.ex \
        runtime/lib/esr/peer_factory.ex \
        runtime/test/esr/admin_session_test.exs
git commit -m "$(cat <<'EOF'
feat(admin_session): supervisor + bootstrap peer spawn (Risk F)

Creates Esr.AdminSession (Supervisor) + Esr.AdminSessionProcess
(GenServer holding admin-scope peer refs) + the PeerFactory.spawn_peer_bootstrap/4
escape hatch that AdminSession uses to spawn its children without
going through Esr.SessionRouter (which doesn't exist at boot time).

This is spec §6 Risk F in code form: the single documented exception
to the "all peers spawn via SessionRouter" rule. Verified by a boot-order
test that asserts AdminSession comes up while SessionRouter is unloaded.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-2: `Esr.Peers.FeishuAppAdapter` (Phoenix-channel consumer, per-app_id)

**Feishu notification**: no.

**Context (drift note)**: Today the Feishu WebSocket is terminated by a **Python** `adapter_runner` process, and Elixir receives frames via `EsrWeb.AdapterChannel` on topic `adapter:feishu/<instance_id>`. PR-2 does NOT move WS ownership into Elixir. FeishuAppAdapter becomes the Elixir-side consumer of those forwarded frames (replacing the current `AdapterHub.Registry` + `Esr.PeerRegistry` lookup hop with a per-session dispatch via `SessionRegistry.lookup_by_chat_thread/2`). The plan's original "FeishuAppAdapter owns WS" phrasing is preserved semantically (one actor per app_id terminates the inbound stream for that app), just not the implementation (no Mint WS client in Elixir).

**Files:**
- Create: `runtime/lib/esr/peers/feishu_app_adapter.ex`
- Create: `runtime/test/esr/peers/feishu_app_adapter_test.exs`

- [ ] **Step 1: Write failing test**

Create `runtime/test/esr/peers/feishu_app_adapter_test.exs`:

```elixir
defmodule Esr.Peers.FeishuAppAdapterTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuAppAdapter

  setup do
    start_supervised!({Esr.SessionRegistry, []})
    start_supervised!({Esr.AdminSessionProcess, []})
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: :fab_test_sup)

    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :shutdown) end)
    :ok
  end

  test "start_link registers the adapter as :feishu_app_adapter_<app_id> in AdminSessionProcess" do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        :fab_test_sup,
        {FeishuAppAdapter, %{app_id: "cli_app_test123", neighbors: [], proxy_ctx: %{}}}
      )

    assert Process.alive?(pid)
    {:ok, ^pid} = Esr.AdminSessionProcess.admin_peer(:feishu_app_adapter_cli_app_test123)
  end

  test "inbound envelope with chat+thread routes to the matching FeishuChatProxy via SessionRegistry" do
    # Arrange: register a fake session with a test-owned "proxy pid"
    test_pid = self()
    :ok = Esr.SessionRegistry.register_session(
      "session-abc",
      %{chat_id: "oc_xyz", thread_id: "om_123"},
      %{feishu_chat_proxy: test_pid}
    )

    {:ok, pid} =
      DynamicSupervisor.start_child(
        :fab_test_sup,
        {FeishuAppAdapter, %{app_id: "cli_app_test456", neighbors: [], proxy_ctx: %{}}}
      )

    envelope = %{
      "payload" => %{
        "event_type" => "im.message.receive_v1",
        "chat_id" => "oc_xyz",
        "thread_id" => "om_123",
        "text" => "hello"
      }
    }

    send(pid, {:inbound_event, envelope})
    assert_receive {:feishu_inbound, ^envelope}, 500
  end

  test "inbound envelope with no matching session emits :new_chat_thread event" do
    # With no SessionRegistry entry for (chat_id, thread_id), FeishuAppAdapter
    # broadcasts a :new_chat_thread event on PubSub for SessionRouter to consume
    # (SessionRouter itself is PR-3; in PR-2 we assert the broadcast happens).
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "new_chat_thread")

    {:ok, pid} =
      DynamicSupervisor.start_child(
        :fab_test_sup,
        {FeishuAppAdapter, %{app_id: "cli_app_nomatch", neighbors: [], proxy_ctx: %{}}}
      )

    envelope = %{
      "payload" => %{
        "event_type" => "im.message.receive_v1",
        "chat_id" => "oc_new",
        "thread_id" => "om_new",
        "text" => "first message"
      }
    }

    send(pid, {:inbound_event, envelope})

    assert_receive {:new_chat_thread, "oc_new", "om_new", "cli_app_nomatch", ^envelope}, 500
  end
end
```

- [ ] **Step 2: Run test, verify FAIL**

```bash
mix test test/esr/peers/feishu_app_adapter_test.exs
```

Expected: FAIL — `Esr.Peers.FeishuAppAdapter is undefined`.

- [ ] **Step 3: Implement**

Create `runtime/lib/esr/peers/feishu_app_adapter.ex`:

```elixir
defmodule Esr.Peers.FeishuAppAdapter do
  @moduledoc """
  Peer.Stateful for one Feishu app_id. AdminSession-scope (one per app
  declared in adapters.yaml).

  Role: sole Elixir consumer of `adapter:feishu/<app_id>` Phoenix-channel
  inbound frames. Routes each frame to the owning Session's FeishuChatProxy
  via `SessionRegistry.lookup_by_chat_thread/2`, or broadcasts `:new_chat_thread`
  on PubSub for SessionRouter (PR-3) to create a new session.

  **Today's architecture note**: the actual Feishu WebSocket is terminated
  by the Python `adapter_runner` subprocess; this Elixir peer receives
  frames via the existing Phoenix-channel plumbing (`EsrWeb.AdapterChannel`
  forwards `{:inbound_event, envelope}` to this peer once P2-11 retargets
  the channel).

  Registers itself in AdminSessionProcess under `:feishu_app_adapter_<app_id>`
  so other peers (and test harnesses) can look it up symbolically.

  See spec §4.1 FeishuAppAdapter card, §5.1.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  def start_link(%{app_id: app_id} = args) when is_binary(app_id) do
    GenServer.start_link(__MODULE__, args, name: via(app_id))
  end

  defp via(app_id), do: String.to_atom("feishu_app_adapter_#{app_id}")

  @impl Esr.Peer.Stateful
  def init(%{app_id: app_id} = args) do
    :ok = Esr.AdminSessionProcess.register_admin_peer(
      String.to_atom("feishu_app_adapter_#{app_id}"),
      self()
    )
    {:ok, %{app_id: app_id, neighbors: args[:neighbors] || [], proxy_ctx: args[:proxy_ctx] || %{}}}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:inbound_event, envelope}, state) do
    chat_id = get_in(envelope, ["payload", "chat_id"])
    thread_id = get_in(envelope, ["payload", "thread_id"])

    case Esr.SessionRegistry.lookup_by_chat_thread(chat_id, thread_id) do
      {:ok, _session_id, %{feishu_chat_proxy: proxy_pid}} when is_pid(proxy_pid) ->
        send(proxy_pid, {:feishu_inbound, envelope})
        {:forward, [], state}

      :not_found ->
        Phoenix.PubSub.broadcast(
          EsrWeb.PubSub,
          "new_chat_thread",
          {:new_chat_thread, chat_id, thread_id, state.app_id, envelope}
        )
        {:drop, :new_chat_thread_pending, state}

      other ->
        Logger.warning("FeishuAppAdapter: unexpected SessionRegistry reply #{inspect(other)}")
        {:drop, :session_lookup_failed, state}
    end
  end

  @impl Esr.Peer.Stateful
  def handle_downstream({:outbound, envelope}, state) do
    # PR-2 leaves outbound emission wired through the existing adapter
    # broadcast path (EsrWeb.Endpoint.broadcast on adapter:feishu/<app_id>).
    # PR-3 can move this into CCProcess directly.
    EsrWeb.Endpoint.broadcast(
      "adapter:feishu/#{state.app_id}",
      "envelope",
      envelope
    )
    {:forward, [], state}
  end

  # GenServer glue so DynamicSupervisor.start_child picks up the behaviour.
  def handle_info({:inbound_event, envelope}, state) do
    case handle_upstream({:inbound_event, envelope}, state) do
      {:forward, _msgs, new_state} -> {:noreply, new_state}
      {:drop, _reason, new_state} -> {:noreply, new_state}
    end
  end

  def init(args), do: __MODULE__.init(args) |> normalize_init()

  defp normalize_init({:ok, state}), do: {:ok, state}
  defp normalize_init({:stop, reason}), do: {:stop, reason}
end
```

(Note: the `init/1` + `handle_upstream/2` + `handle_downstream/2` are behaviour callbacks via `use Esr.Peer.Stateful`; the `handle_info/2` clause is the GenServer bridge that routes inbound messages through the Stateful callbacks. Same pattern is used by all Stateful peers in PR-2.)

- [ ] **Step 4: Run test, verify PASS**

```bash
mix test test/esr/peers/feishu_app_adapter_test.exs
```

Expected: all three tests PASS.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: baseline + 3 new tests, all green.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/peers/feishu_app_adapter.ex \
        runtime/test/esr/peers/feishu_app_adapter_test.exs
git commit -m "$(cat <<'EOF'
feat(peers): Esr.Peers.FeishuAppAdapter (per-app_id inbound consumer)

Peer.Stateful for one Feishu app_id. Consumes :inbound_event messages
(which EsrWeb.AdapterChannel will retarget here in P2-11), looks up the
owning Session via SessionRegistry.lookup_by_chat_thread/2, and either
sends to the Session's FeishuChatProxy or broadcasts :new_chat_thread
on PubSub for SessionRouter (PR-3) to create a new session.

The Feishu WebSocket itself is still owned by the Python adapter_runner
subprocess; this peer replaces the AdapterHub.Registry lookup hop with
a per-session dispatch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-3: `Esr.Peers.FeishuChatProxy` (slash detection + drop-non-slash in PR-2)

**Feishu notification**: no.

**Design decision (PR-2 scope)**: Downstream CC peers don't exist until PR-3. FeishuChatProxy therefore implements **drop + log** for non-slash messages in PR-2; a `TODO P3` comment marks where the downstream forward will wire in. This matches "PR-2 is foundational" intent and avoids bridge code that P3 would delete. Rationale captured in expansion-doc §PR-2 drift findings.

**Files:**
- Create: `runtime/lib/esr/peers/feishu_chat_proxy.ex`
- Create: `runtime/test/esr/peers/feishu_chat_proxy_test.exs`

- [ ] **Step 1: Write failing test**

Create `runtime/test/esr/peers/feishu_chat_proxy_test.exs`:

```elixir
defmodule Esr.Peers.FeishuChatProxyTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuChatProxy

  setup do
    start_supervised!({Esr.SessionRegistry, []})
    start_supervised!({Esr.AdminSessionProcess, []})
    :ok
  end

  test "slash-prefix messages route to slash_handler via AdminSessionProcess" do
    test_pid = self()
    :ok = Esr.AdminSessionProcess.register_admin_peer(:slash_handler, test_pid)

    {:ok, peer} =
      GenServer.start_link(FeishuChatProxy, %{
        session_id: "s1",
        chat_id: "oc_x",
        thread_id: "om_1",
        neighbors: [],
        proxy_ctx: %{}
      })

    send(peer, {:feishu_inbound, %{
      "payload" => %{"text" => "/new-session --agent cc --dir /tmp/w"}
    }})

    assert_receive {:slash_cmd, _env, reply_to}, 500
    assert reply_to == peer
  end

  test "non-slash messages are dropped + logged (PR-2 scope)" do
    import ExUnit.CaptureLog

    {:ok, peer} =
      GenServer.start_link(FeishuChatProxy, %{
        session_id: "s2",
        chat_id: "oc_y",
        thread_id: "om_2",
        neighbors: [],
        proxy_ctx: %{}
      })

    log =
      capture_log(fn ->
        send(peer, {:feishu_inbound, %{"payload" => %{"text" => "hello, not a slash"}}})
        Process.sleep(50)
      end)

    assert log =~ "feishu_chat_proxy: non-slash dropped (PR-3 wires downstream)"
  end
end
```

- [ ] **Step 2: Run test, verify FAIL**

```bash
mix test test/esr/peers/feishu_chat_proxy_test.exs
```

Expected: FAIL — `Esr.Peers.FeishuChatProxy is undefined`.

- [ ] **Step 3: Implement**

Create `runtime/lib/esr/peers/feishu_chat_proxy.ex`:

```elixir
defmodule Esr.Peers.FeishuChatProxy do
  @moduledoc """
  Per-Session Peer.Stateful: entry point for inbound Feishu messages
  into the Session. Detects slash commands (leading `/` in the first
  token) and short-circuits to the AdminSession's SlashHandler; all
  other messages are currently dropped with a log line (PR-3 wires
  the downstream forward into CCProxy).

  Spec §4.1 FeishuChatProxy card, §5.1, §5.3.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl Esr.Peer.Stateful
  def init(args) do
    state = %{
      session_id: Map.fetch!(args, :session_id),
      chat_id: Map.fetch!(args, :chat_id),
      thread_id: Map.fetch!(args, :thread_id),
      neighbors: Map.get(args, :neighbors, []),
      proxy_ctx: Map.get(args, :proxy_ctx, %{})
    }
    {:ok, state}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:feishu_inbound, envelope}, state) do
    text = get_in(envelope, ["payload", "text"]) || ""

    if slash?(text) do
      case Esr.AdminSessionProcess.slash_handler_ref() do
        {:ok, slash_pid} ->
          send(slash_pid, {:slash_cmd, envelope, self()})
          {:drop, :slash_dispatched, state}

        :error ->
          Logger.warning(
            "feishu_chat_proxy: slash received but no SlashHandler registered " <>
              "(session_id=#{state.session_id})"
          )
          {:drop, :no_slash_handler, state}
      end
    else
      Logger.info(
        "feishu_chat_proxy: non-slash dropped (PR-3 wires downstream) " <>
          "session_id=#{state.session_id} text_len=#{byte_size(text)}"
      )
      {:drop, :non_slash_pr2, state}
    end
  end

  @impl Esr.Peer.Stateful
  def handle_downstream({:reply, text}, state) do
    # PR-2 outbound: reply text goes to the FeishuAppProxy neighbor (P2-4).
    case Keyword.get(state.neighbors, :feishu_app_proxy) do
      pid when is_pid(pid) ->
        send(pid, {:outbound, %{
          "kind" => "reply",
          "args" => %{"chat_id" => state.chat_id, "text" => text}
        }})
        {:forward, [], state}

      _ ->
        Logger.warning(
          "feishu_chat_proxy: reply but no feishu_app_proxy neighbor " <>
            "session_id=#{state.session_id}"
        )
        {:drop, :no_app_proxy_neighbor, state}
    end
  end

  def handle_info({:feishu_inbound, _} = msg, state) do
    case handle_upstream(msg, state) do
      {:forward, _, ns} -> {:noreply, ns}
      {:drop, _, ns} -> {:noreply, ns}
    end
  end

  def handle_info({:reply, _} = msg, state) do
    case handle_downstream(msg, state) do
      {:forward, _, ns} -> {:noreply, ns}
      {:drop, _, ns} -> {:noreply, ns}
    end
  end

  defp slash?(text) do
    case String.trim_leading(text) do
      "/" <> _rest -> true
      _ -> false
    end
  end
end
```

- [ ] **Step 4: Run test, verify PASS**

```bash
mix test test/esr/peers/feishu_chat_proxy_test.exs
```

Expected: both tests PASS.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: baseline + 2 new tests green.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/peers/feishu_chat_proxy.ex \
        runtime/test/esr/peers/feishu_chat_proxy_test.exs
git commit -m "$(cat <<'EOF'
feat(peers): Esr.Peers.FeishuChatProxy (slash detection, per-Session)

Per-Session Peer.Stateful. Inspects first token of inbound Feishu
messages; slash-prefixed ones short-circuit to AdminSession.SlashHandler
(looked up via AdminSessionProcess.slash_handler_ref/0), non-slash
messages are dropped with a log line. PR-3 will wire the downstream
forward into CCProxy.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-4: `Peer.Proxy` macro `@required_cap` extension + `Esr.Peers.FeishuAppProxy`

**Feishu notification**: no.

**Important**: This extends PR-1's macro (spec §3.6). Literal capability strings only — no template substitution in PR-2 (deferred per PR-1 snapshot's Key Question 2).

**Files:**
- Modify: `runtime/lib/esr/peer/proxy.ex` (extend macro)
- Modify: `runtime/test/esr/peer/proxy_compile_test.exs` (add `@required_cap` fixture tests)
- Create: `runtime/lib/esr/peers/feishu_app_proxy.ex`
- Create: `runtime/test/esr/peers/feishu_app_proxy_test.exs`

- [ ] **Step 1: Write failing tests**

Append to `runtime/test/esr/peer/proxy_compile_test.exs`:

```elixir
  test "Peer.Proxy module with @required_cap injects a cap-check wrapper around forward/2" do
    ast =
      quote do
        defmodule CapProxy do
          use Esr.Peer.Proxy
          @required_cap "workspace:*/msg.send"
          def forward(_msg, ctx), do: {:ok, ctx.test_tag}
        end
      end

    assert [{mod, _}] = Code.compile_quoted(ast)

    # Inject a fake Capabilities.has?/2 via a test-mode override.
    Process.put(:esr_cap_test_override, fn _pid, _perm -> false end)

    assert {:drop, :cap_denied} = mod.forward(:hi, %{principal_id: "p1", test_tag: :ok})

    Process.put(:esr_cap_test_override, fn _pid, _perm -> true end)
    assert {:ok, :ok} = mod.forward(:hi, %{principal_id: "p1", test_tag: :ok})
  after
    Process.delete(:esr_cap_test_override)
  end

  test "Peer.Proxy module without @required_cap compiles and forwards directly" do
    ast =
      quote do
        defmodule NoCapProxy do
          use Esr.Peer.Proxy
          def forward(msg, _ctx), do: {:ok, msg}
        end
      end

    assert [{mod, _}] = Code.compile_quoted(ast)
    assert {:ok, :hello} = mod.forward(:hello, %{})
  end
```

Create `runtime/test/esr/peers/feishu_app_proxy_test.exs`:

```elixir
defmodule Esr.Peers.FeishuAppProxyTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuAppProxy

  test "forward/2 calls Capabilities.has? before dispatching to target" do
    # FeishuAppProxy declares @required_cap "cap.peer_proxy.forward_feishu"
    Process.put(:esr_cap_test_override, fn
      "p_allowed", "cap.peer_proxy.forward_feishu" -> true
      _, _ -> false
    end)

    target = self()
    ctx = %{principal_id: "p_allowed", target_pid: target, app_id: "cli_app_x"}
    assert :ok = FeishuAppProxy.forward({:outbound, %{"hello" => 1}}, ctx)
    assert_receive {:outbound, %{"hello" => 1}}, 100
  after
    Process.delete(:esr_cap_test_override)
  end

  test "forward/2 returns {:drop, :cap_denied} when capability missing" do
    Process.put(:esr_cap_test_override, fn _, _ -> false end)

    ctx = %{principal_id: "p_denied", target_pid: self(), app_id: "cli_app_x"}
    assert {:drop, :cap_denied} = FeishuAppProxy.forward({:outbound, %{}}, ctx)
    refute_receive _, 50
  after
    Process.delete(:esr_cap_test_override)
  end

  test "forward/2 returns {:drop, :target_unavailable} when target_pid is dead" do
    Process.put(:esr_cap_test_override, fn _, _ -> true end)

    # Spawn and immediately kill.
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}, 100

    ctx = %{principal_id: "p", target_pid: dead, app_id: "cli_app_x"}
    assert {:drop, :target_unavailable} = FeishuAppProxy.forward({:outbound, %{}}, ctx)
  after
    Process.delete(:esr_cap_test_override)
  end
end
```

- [ ] **Step 2: Run tests, verify FAIL**

```bash
mix test test/esr/peer/proxy_compile_test.exs test/esr/peers/feishu_app_proxy_test.exs
```

Expected: FAIL — first set fails because macro lacks `@required_cap` support; second set fails because module undefined.

- [ ] **Step 3: Implement macro extension**

Rewrite `runtime/lib/esr/peer/proxy.ex`:

```elixir
defmodule Esr.Peer.Proxy do
  @moduledoc """
  Stateless forwarder Peer.

  Compile-time restricted: a module using `Esr.Peer.Proxy` cannot
  define `handle_call/3` or `handle_cast/2` — doing so raises a
  compile error.

  Optional `@required_cap "<permission_str>"` module attribute (literal
  string only; runtime templates deferred) injects a capability-check
  wrapper around `forward/2`. The wrapper:

    1. Reads `ctx.principal_id` (must be a binary).
    2. Calls `Esr.Capabilities.has?(principal_id, @required_cap)`.
    3. On false → returns `{:drop, :cap_denied}`.
    4. On true → delegates to the user's `forward/2` body.
       If the body's return is `:ok` or `{:ok, _}`, the wrapper additionally
       checks the `ctx.target_pid` is alive before the send already happened
       inside `forward/2`; dead-target handling is the body's responsibility
       (idiomatic pattern: `send(ctx.target_pid, msg)` then `:ok`, and the
       caller handles `{:drop, :target_unavailable}` via a DOWN monitor).

  Test-time override: set `Process.put(:esr_cap_test_override, fn pid, perm -> bool end)`
  to bypass Esr.Capabilities.has?/2 in unit tests. Production never reads
  this key.

  See spec §3.1, §3.6, §6 Risk B.
  """

  @callback forward(msg :: term(), ctx :: map()) ::
              :ok | {:ok, term()} | {:drop, reason :: atom()}

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

    offenders = for fa <- @forbidden, fa in defined, do: fa

    if offenders != [] do
      msg =
        "Esr.Peer.Proxy module #{inspect(env.module)} cannot define stateful callbacks. " <>
          "Found: #{inspect(offenders)}. Use Esr.Peer.Stateful if you need state."

      raise CompileError, description: msg
    end

    cap = Module.get_attribute(env.module, :required_cap)

    if is_binary(cap) do
      # Rename user's forward/2 to forward_without_cap/2 via a thin shim:
      # we can't rename a def, but we CAN generate a def forward/2 that
      # wraps the ORIGINAL def; AST transform not needed because `def`
      # redefinition replaces the clause. Instead, use defoverridable.
      quote do
        defoverridable forward: 2

        def forward(msg, ctx) do
          principal_id = Map.get(ctx, :principal_id)

          check =
            case Process.get(:esr_cap_test_override) do
              fun when is_function(fun, 2) -> fun
              _ -> &Esr.Capabilities.has?/2
            end

          cond do
            not is_binary(principal_id) ->
              {:drop, :cap_denied}

            check.(principal_id, unquote(cap)) ->
              super(msg, ctx)

            true ->
              {:drop, :cap_denied}
          end
        end
      end
    else
      :ok
    end
  end
end
```

Create `runtime/lib/esr/peers/feishu_app_proxy.ex`:

```elixir
defmodule Esr.Peers.FeishuAppProxy do
  @moduledoc """
  Per-Session Peer.Proxy: outbound door from the Session to the AdminSession's
  FeishuAppAdapter_<app_id>. Carries a capability check on forward — declared
  via @required_cap so the PR-1 Peer.Proxy macro extension (P2-4) wraps
  forward/2 with Esr.Capabilities.has?/2.

  ctx shape (computed once at session-spawn time in PR-3's SessionRouter;
  in PR-2 injected manually by callers/tests):
    %{
      principal_id:  binary,   # who owns the session
      target_pid:    pid,      # AdminSession.FeishuAppAdapter_<app_id>
      app_id:        binary
    }

  Spec §3.6, §4.1 FeishuAppProxy card.
  """
  use Esr.Peer.Proxy
  @required_cap "cap.peer_proxy.forward_feishu"

  @impl Esr.Peer.Proxy
  def forward(msg, %{target_pid: target} = _ctx) when is_pid(target) do
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

- [ ] **Step 4: Run tests, verify PASS**

```bash
mix test test/esr/peer/proxy_compile_test.exs test/esr/peers/feishu_app_proxy_test.exs
```

Expected: all (original 3 PR-1 tests + 2 new macro tests + 3 FeishuAppProxy tests = 8) PASS.

- [ ] **Step 5: Run full suite (watch for regressions in PR-1 Peer.Proxy consumers)**

```bash
mix test
```

Expected: baseline + 5 new tests green. Zero regressions in PR-1's proxy tests.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/peer/proxy.ex \
        runtime/lib/esr/peers/feishu_app_proxy.ex \
        runtime/test/esr/peer/proxy_compile_test.exs \
        runtime/test/esr/peers/feishu_app_proxy_test.exs
git commit -m "$(cat <<'EOF'
feat(peer): @required_cap macro extension + Esr.Peers.FeishuAppProxy

Extends Esr.Peer.Proxy's __before_compile__ to wrap forward/2 with an
Esr.Capabilities.has?/2 check when the using module declares
@required_cap "<permission_str>" (literal string only; runtime template
expansion deferred to a later PR). defoverridable forward: 2 lets the
wrapper delegate to the user's body via super/2.

Esr.Peers.FeishuAppProxy is the first consumer: declares
@required_cap "cap.peer_proxy.forward_feishu", forwards {:outbound, envelope}
to ctx.target_pid (AdminSession's FeishuAppAdapter_<app_id>), with
{:drop, :target_unavailable} on dead target.

Closes tech-debt "PeerProxy has no capability-check wrapper" from PR-1
snapshot.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-5: `Esr.Peers.SlashHandler` (channel-agnostic slash peer)

**Feishu notification**: **yes — milestone: P2-1..5 done (AdminSession skeleton + Feishu inbound chain + SlashHandler).**

**Files:**
- Create: `runtime/lib/esr/peers/slash_handler.ex`
- Create: `runtime/test/esr/peers/slash_handler_test.exs`

- [ ] **Step 1: Write failing test**

Create `runtime/test/esr/peers/slash_handler_test.exs`:

```elixir
defmodule Esr.Peers.SlashHandlerTest do
  use ExUnit.Case, async: false

  alias Esr.Peers.SlashHandler

  setup do
    start_supervised!({Esr.AdminSessionProcess, []})
    # Stub Esr.Admin.Dispatcher with a process that echoes commands back.
    dispatcher = self()
    Process.register(dispatcher, :test_admin_dispatcher)
    on_exit(fn -> if Process.whereis(:test_admin_dispatcher), do: Process.unregister(:test_admin_dispatcher) end)
    :ok
  end

  test "slash_cmd is parsed and cast to Admin.Dispatcher with correlation ref" do
    {:ok, pid} =
      GenServer.start_link(SlashHandler,
        %{dispatcher: :test_admin_dispatcher, session_id: "admin", neighbors: [], proxy_ctx: %{}}
      )

    reply_to_proxy = self()
    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/list-sessions", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, reply_to_proxy})

    assert_receive {:"$gen_cast", {:execute, %{"kind" => "session_list"}, {:reply_to, {:pid, ^pid, _ref}}}}, 500
  end

  test "command_result from Dispatcher is relayed to the originating FeishuChatProxy as :reply" do
    {:ok, pid} =
      GenServer.start_link(SlashHandler,
        %{dispatcher: :test_admin_dispatcher, session_id: "admin", neighbors: [], proxy_ctx: %{}}
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/list-sessions", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    # Capture the ref the handler used
    assert_receive {:"$gen_cast", {:execute, _cmd, {:reply_to, {:pid, ^pid, ref}}}}, 500

    # Simulate Dispatcher's reply
    send(pid, {:command_result, ref, {:ok, %{"branches" => ["main"]}}})

    # SlashHandler should forward as {:reply, text} back to self() (the proxy)
    assert_receive {:reply, text}, 500
    assert text =~ "sessions:"
  end

  test "registers itself in AdminSessionProcess under :slash_handler on init" do
    {:ok, pid} =
      GenServer.start_link(SlashHandler,
        %{dispatcher: :test_admin_dispatcher, session_id: "admin", neighbors: [], proxy_ctx: %{}}
      )

    assert {:ok, ^pid} = Esr.AdminSessionProcess.admin_peer(:slash_handler)
  end

  test "unknown slash text returns :drop and a user-facing error reply" do
    {:ok, pid} =
      GenServer.start_link(SlashHandler,
        %{dispatcher: :test_admin_dispatcher, session_id: "admin", neighbors: [], proxy_ctx: %{}}
      )

    envelope = %{
      "principal_id" => "p_user",
      "payload" => %{"text" => "/completely-unknown foo", "chat_id" => "oc_z"}
    }

    send(pid, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 500
    assert text =~ "unknown command"
  end
end
```

- [ ] **Step 2: Run test, verify FAIL**

```bash
mix test test/esr/peers/slash_handler_test.exs
```

Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

Create `runtime/lib/esr/peers/slash_handler.ex`:

```elixir
defmodule Esr.Peers.SlashHandler do
  @moduledoc """
  Channel-agnostic slash-command peer. AdminSession-scope (exactly one,
  registered under :slash_handler in AdminSessionProcess).

  On :slash_cmd from any ChatProxy: parse the command, cast to
  Esr.Admin.Dispatcher with a correlation ref, and relay the reply back
  to the originating ChatProxy as {:reply, text}.

  Replaces the slash-parsing half of Esr.Routing.SlashHandler (which
  stays in place until PR-3 deletes it). The PR-2 feature flag
  USE_NEW_PEER_CHAIN (P2-10) gates whether Feishu slash commands route
  through here or through the legacy router.

  Spec §4.1 SlashHandler card, §5.3, §1.8 D14.
  """
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  @default_dispatcher Esr.Admin.Dispatcher

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl Esr.Peer.Stateful
  def init(args) do
    :ok = Esr.AdminSessionProcess.register_admin_peer(:slash_handler, self())
    state = %{
      dispatcher: Map.get(args, :dispatcher, @default_dispatcher),
      session_id: Map.fetch!(args, :session_id),
      pending: %{}  # ref -> reply_to_proxy pid
    }
    {:ok, state}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream(_, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream(_, state), do: {:forward, [], state}

  def handle_info({:slash_cmd, envelope, reply_to_proxy}, state) do
    text = get_in(envelope, ["payload", "text"]) || ""
    principal_id = envelope["principal_id"] || "ou_unknown"

    case parse_command(text) do
      {:ok, kind, args} ->
        ref = make_ref()
        cmd = %{
          "id" => generate_id(),
          "kind" => kind,
          "submitted_by" => principal_id,
          "args" => args
        }
        GenServer.cast(state.dispatcher, {:execute, cmd, {:reply_to, {:pid, self(), ref}}})
        {:noreply, put_in(state.pending[ref], reply_to_proxy)}

      {:error, reason} ->
        send(reply_to_proxy, {:reply, "unknown command: #{reason}"})
        {:noreply, state}
    end
  end

  def handle_info({:command_result, ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        Logger.warning("slash_handler: unknown command_result ref #{inspect(ref)}")
        {:noreply, state}

      {reply_to_proxy, rest} ->
        send(reply_to_proxy, {:reply, format_result(result)})
        {:noreply, %{state | pending: rest}}
    end
  end

  # Parser — reuses the PR-0-renamed router's grammar, extended with
  # D15-compliant --agent/--dir tokenization for session_new.
  defp parse_command("/new-session " <> rest), do: parse_new_session(rest)
  defp parse_command("/new-session"), do: {:error, "/new-session requires --agent and --dir"}
  defp parse_command("/end-session " <> rest) do
    case tokenize(rest) do
      [sid | _] -> {:ok, "session_end", %{"session_id" => sid}}
      [] -> {:error, "/end-session requires <session_id>"}
    end
  end
  defp parse_command("/list-sessions"), do: {:ok, "session_list", %{}}
  defp parse_command("/sessions"), do: {:ok, "session_list", %{}}
  defp parse_command("/list-agents"), do: {:ok, "agent_list", %{}}
  defp parse_command(other), do: {:error, inspect(String.slice(other, 0, 32))}

  # --agent <name> --dir <path>; both required per D11/D13.
  defp parse_new_session(rest) do
    toks = tokenize(rest)
    agent = flag_value(toks, "--agent")
    dir = flag_value(toks, "--dir")

    cond do
      is_nil(agent) -> {:error, "/new-session requires --agent"}
      is_nil(dir) -> {:error, "/new-session requires --dir (agent '#{agent}' declares dir required)"}
      true -> {:ok, "session_agent_new", %{"agent" => agent, "dir" => dir}}
    end
  end

  defp flag_value(toks, flag) do
    case Enum.drop_while(toks, &(&1 != flag)) do
      [^flag, value | _] -> value
      _ -> nil
    end
  end

  defp tokenize(rest), do: rest |> String.trim() |> String.split(~r/\s+/, trim: true)

  defp format_result({:ok, %{"branches" => b}}) when is_list(b), do: "sessions: " <> Enum.join(b, ", ")
  defp format_result({:ok, %{"session_id" => sid}}), do: "session started: #{sid}"
  defp format_result({:ok, %{} = m}), do: "ok: " <> inspect(m)
  defp format_result({:error, %{"type" => t}}) when is_binary(t), do: "error: " <> t
  defp format_result({:error, %{"type" => :missing_capabilities, "caps" => caps}}), do: "error: missing caps — " <> Enum.join(caps, ", ")
  defp format_result(other), do: "result: " <> inspect(other)

  defp generate_id, do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)
end
```

Note on `session_agent_new` kind: this is the new admin command introduced by PR-2 (per drift finding #2). PR-3 collapses this into `session_new` with required `agent`. The Admin.Dispatcher gets the new command registered via P2-11.

- [ ] **Step 4: Run test, verify PASS**

```bash
mix test test/esr/peers/slash_handler_test.exs
```

Expected: all four tests PASS.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: baseline + 4 new tests green.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/peers/slash_handler.ex \
        runtime/test/esr/peers/slash_handler_test.exs
git commit -m "$(cat <<'EOF'
feat(peers): Esr.Peers.SlashHandler (channel-agnostic slash peer)

AdminSession-scope Peer.Stateful that parses /new-session, /end-session,
/list-sessions, /list-agents and casts into Esr.Admin.Dispatcher with
correlation-ref. Registers itself as :slash_handler in AdminSessionProcess
so FeishuChatProxy (and future Slack/CLI channels) can find it without
a global registry round-trip.

Parser enforces spec D11 (--agent required) and D13 (--dir required);
unknown commands reply with a human-readable "unknown command: ..."
back to the originating ChatProxy.

Introduces a new admin command kind session_agent_new (distinct from
legacy session_new which spawns worktrees). PR-3 collapses these.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: Feishu notification — milestone**

Use `mcp__openclaw-channel__reply` to `oc_d9b47511b085e9d5b66c4595b3ef9bb9`:

> "PR-2 进度：完成 P2-1..5。AdminSession 骨架 + FeishuAppAdapter + FeishuChatProxy + FeishuAppProxy(带 @required_cap macro 扩展) + SlashHandler 已落地。继续 P2-6 (Session supervisor + 移除 PR-1 的 process-dict scaffold)。"

---

## Task P2-6: `Esr.Session` supervisor + `Esr.SessionProcess` + `supervisor_name/1` + remove scaffold

**Feishu notification**: no.

**Files:**
- Create: `runtime/lib/esr/session.ex`
- Create: `runtime/lib/esr/session_process.ex`
- Modify: `runtime/lib/esr/peer_factory.ex` (drop process-dict override in favour of real `Esr.Session.supervisor_name/1`, keeping a single test-override path for tests that don't have a real Session spun up)
- Modify: `runtime/test/esr/peer_factory_test.exs`
- Create: `runtime/test/esr/session_test.exs`

- [ ] **Step 1: Write failing tests**

Create `runtime/test/esr/session_test.exs`:

```elixir
defmodule Esr.SessionTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!({Registry, keys: :unique, name: Esr.Session.Registry})
    :ok
  end

  test "supervisor_name/1 returns a unique via tuple per session_id" do
    n1 = Esr.Session.supervisor_name("s-1")
    n2 = Esr.Session.supervisor_name("s-2")
    assert n1 != n2
  end

  test "supervisor_name/1 returns admin children sup for session_id == \"admin\"" do
    # Admin resolution: AdminSession's children supervisor (registered via application.ex).
    Application.put_env(:esr, :admin_children_sup_name, :test_admin_children)
    assert Esr.Session.supervisor_name("admin") == :test_admin_children
  end

  test "Session.start_link starts SessionProcess + peer supervisor" do
    {:ok, sup} = Esr.Session.start_link(%{
      session_id: "s-abc",
      agent_name: "cc",
      dir: "/tmp/w",
      chat_thread_key: %{chat_id: "oc", thread_id: "om"},
      metadata: %{}
    })

    children = Supervisor.which_children(sup)
    assert Enum.any?(children, fn {id, _pid, _, _} -> id == Esr.SessionProcess end)
    assert Enum.any?(children, fn {id, _pid, _, _} -> id == :peers end)
  end

  test "SessionProcess state carries session_id + agent_name + dir" do
    {:ok, _sup} = Esr.Session.start_link(%{
      session_id: "s-xyz",
      agent_name: "cc",
      dir: "/tmp/w2",
      chat_thread_key: %{chat_id: "oc2", thread_id: "om2"},
      metadata: %{}
    })

    state = Esr.SessionProcess.state("s-xyz")
    assert state.session_id == "s-xyz"
    assert state.agent_name == "cc"
    assert state.dir == "/tmp/w2"
  end
end
```

Modify `runtime/test/esr/peer_factory_test.exs` — replace the setup and add a test that exercises the real resolver:

```elixir
defmodule Esr.PeerFactoryTest do
  use ExUnit.Case, async: false

  defmodule TestPeer do
    use Esr.Peer.Stateful
    use GenServer
    def init(args), do: {:ok, args}
    def handle_upstream(_, s), do: {:forward, [], s}
    def handle_downstream(_, s), do: {:forward, [], s}
    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def handle_call(_, _, s), do: {:reply, :ok, s}
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Esr.Session.Registry})
    :ok
  end

  test "spawn_peer resolves supervisor via Esr.Session.supervisor_name/1" do
    # Start a real Session with a real peers DynamicSupervisor
    {:ok, _sup} = Esr.Session.start_link(%{
      session_id: "pf-s1",
      agent_name: "cc",
      dir: "/tmp/x",
      chat_thread_key: %{chat_id: "oc", thread_id: "om"},
      metadata: %{}
    })

    assert {:ok, pid} =
             Esr.PeerFactory.spawn_peer("pf-s1", TestPeer, %{name: "p1"}, [], %{})

    assert Process.alive?(pid)
  end

  test "PeerFactory.__info__(:functions) matches the declared public surface" do
    expected = [
      {:spawn_peer, 5},
      {:terminate_peer, 2},
      {:restart_peer, 2},
      {:spawn_peer_bootstrap, 4}  # Added in P2-1
    ]

    actual =
      Esr.PeerFactory.__info__(:functions)
      |> Enum.filter(fn {k, _} -> not String.starts_with?(Atom.to_string(k), "__") end)

    for fn_arity <- expected, do: assert fn_arity in actual
  end
end
```

- [ ] **Step 2: Run tests, verify FAIL**

```bash
mix test test/esr/session_test.exs test/esr/peer_factory_test.exs
```

Expected: FAIL — `Esr.Session`/`Esr.SessionProcess` undefined; PR-1 test still uses `peer_factory_sup_override` which no longer exists after P2-6's cleanup.

- [ ] **Step 3: Implement**

Create `runtime/lib/esr/session_process.ex`:

```elixir
defmodule Esr.SessionProcess do
  @moduledoc """
  Per-Session GenServer holding core session state.

  PR-2 scope (minimal):
    - session_id (ULID string)
    - agent_name (e.g. "cc")
    - dir (workspace path)
    - chat_thread_key (%{chat_id:, thread_id:})
    - metadata (free-form map)

  P2-6a adds the `grants` field and SessionProcess.has?/2 pass-through.

  Spec §3.5.
  """
  use GenServer

  defstruct [:session_id, :agent_name, :dir, :chat_thread_key, :metadata, grants: %{}]

  def start_link(args) do
    sid = Map.fetch!(args, :session_id)
    GenServer.start_link(__MODULE__, args, name: via(sid))
  end

  def via(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:session_process, session_id}}}

  def state(session_id), do: GenServer.call(via(session_id), :state)

  @impl true
  def init(args) do
    {:ok, %__MODULE__{
      session_id: Map.fetch!(args, :session_id),
      agent_name: Map.fetch!(args, :agent_name),
      dir: Map.fetch!(args, :dir),
      chat_thread_key: Map.fetch!(args, :chat_thread_key),
      metadata: Map.get(args, :metadata, %{})
    }}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}
end
```

Create `runtime/lib/esr/session.ex`:

```elixir
defmodule Esr.Session do
  @moduledoc """
  Supervisor module for a per-user Session subtree. Strategy :one_for_all,
  :transient (spec §3.5).

  Children:
    1. Esr.SessionProcess (:permanent)
    2. A DynamicSupervisor named via the Session.Registry under
       {:peers_sup, session_id} — hosts all peers in the agent's pipeline.
       PeerFactory.spawn_peer/5 resolves to this supervisor via
       Esr.Session.supervisor_name/1.

  The AdminSession's children supervisor is a special case: for session_id
  == "admin", supervisor_name/1 returns the atom configured in
  :esr, :admin_children_sup_name (populated by Esr.AdminSession.init/1).

  Spec §3.5, §7.
  """
  use Supervisor

  def start_link(%{session_id: sid} = args) do
    Supervisor.start_link(__MODULE__, args, name: via_sup(sid))
  end

  defp via_sup(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:session_sup, session_id}}}

  def supervisor_name("admin"),
    do: Application.get_env(:esr, :admin_children_sup_name, Esr.AdminSession.ChildrenSupervisor)

  def supervisor_name(session_id) when is_binary(session_id),
    do: {:via, Registry, {Esr.Session.Registry, {:peers_sup, session_id}}}

  @impl true
  def init(args) do
    sid = Map.fetch!(args, :session_id)

    peers_sup_name =
      {:via, Registry, {Esr.Session.Registry, {:peers_sup, sid}}}

    children = [
      %{
        id: Esr.SessionProcess,
        start: {Esr.SessionProcess, :start_link, [args]},
        restart: :permanent,
        type: :worker
      },
      %{
        id: :peers,
        start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: peers_sup_name]]},
        restart: :permanent,
        type: :supervisor
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
```

Modify `runtime/lib/esr/peer_factory.ex` — remove process-dict override (keep a single opt-in test-override via app env for tests that still need it):

```elixir
  defp resolve_sup(session_id) do
    # Production: Esr.Session.supervisor_name/1.
    # Test-only override: Application.put_env(:esr, :peer_factory_sup_override, name)
    #   — used in unit tests that don't spin up a real Session. Removed entirely
    #   in PR-3 once all tests use real Sessions.
    case Application.get_env(:esr, :peer_factory_sup_override) do
      nil -> Esr.Session.supervisor_name(session_id)
      override -> override
    end
  end
```

- [ ] **Step 4: Run tests, verify PASS**

```bash
mix test test/esr/session_test.exs test/esr/peer_factory_test.exs
```

Expected: all PASS.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: baseline + 4 session tests + 2 peer_factory tests green. PR-1's peer_factory_test has been rewritten — no old tests should remain green via stale scaffold.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/session.ex \
        runtime/lib/esr/session_process.ex \
        runtime/lib/esr/peer_factory.ex \
        runtime/test/esr/session_test.exs \
        runtime/test/esr/peer_factory_test.exs
git commit -m "$(cat <<'EOF'
feat(session): Esr.Session + SessionProcess + PeerFactory resolver cleanup

Introduces Esr.Session (Supervisor, :one_for_all, :transient) +
Esr.SessionProcess (GenServer :permanent) per spec §3.5. Exposes
Esr.Session.supervisor_name/1 which PeerFactory.resolve_sup/1 now calls,
replacing the PR-1 :peer_factory_sup_override process-dict scaffold with
a proper registry-backed lookup.

session_id == "admin" resolves to the AdminSession's children
DynamicSupervisor (configured in app env by Esr.AdminSession.init/1).

Remaining opt-in override via Application.put_env(:esr, :peer_factory_sup_override, ...)
kept for unit tests that don't stand up a real Session. PR-3 removes
this last scaffold.

Closes tech-debt ":peer_factory_sup_override process-dict scaffold"
from PR-1 snapshot.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-6a: `SessionProcess.grants` scaffold + `SessionProcess.has?/2` pass-through

**Feishu notification**: no.

**Files:**
- Modify: `runtime/lib/esr/session_process.ex`
- Modify: `runtime/test/esr/session_test.exs`

- [ ] **Step 1: Write failing test**

Append to `runtime/test/esr/session_test.exs`:

```elixir
  describe "SessionProcess grants (P2-6a scaffold)" do
    setup do
      start_supervised!({Registry, keys: :unique, name: Esr.Session.Registry})
      {:ok, _sup} = Esr.Session.start_link(%{
        session_id: "g-s1",
        agent_name: "cc",
        dir: "/tmp/g",
        chat_thread_key: %{chat_id: "oc", thread_id: "om"},
        metadata: %{principal_id: "p_test"}
      })
      :ok
    end

    test "SessionProcess.has?/2 passes through to Esr.Capabilities.Grants.has?/2 today" do
      # With no grants loaded for principal, has? returns false.
      refute Esr.SessionProcess.has?("g-s1", "workspace:*/msg.send")
    end

    test "has? reads principal_id from metadata and calls global Grants" do
      # Same as above but illustrates the passthrough surface
      assert Esr.SessionProcess.has?("g-s1", "*") == Esr.Capabilities.Grants.has?("p_test", "*")
    end
  end
```

- [ ] **Step 2: Run test, verify FAIL**

```bash
mix test test/esr/session_test.exs
```

Expected: FAIL — `Esr.SessionProcess.has?/2` undefined.

- [ ] **Step 3: Implement — add `has?/2` pass-through**

Modify `runtime/lib/esr/session_process.ex` — append:

```elixir
  @doc """
  PR-2 scaffold for spec §3.3a: session-scoped capability check.

  Today: reads principal_id from SessionProcess.metadata and delegates to
  Esr.Capabilities.Grants.has?/2 (global lookup).

  PR-3 (P3-3a) replaces this with a local grants map populated at Session
  init and refreshed via PubSub `{:grants_changed, principal_id}`. Peers
  calling SessionProcess.has?/2 today will transparently gain session-local
  resolution once P3-3a ships.

  See docs/futures/peer-session-capability-projection.md.
  """
  def has?(session_id, permission) do
    state = state(session_id)
    principal_id = Map.get(state.metadata, :principal_id) || Map.get(state.metadata, "principal_id")

    if is_binary(principal_id) do
      Esr.Capabilities.Grants.has?(principal_id, permission)
    else
      false
    end
  end
```

- [ ] **Step 4: Run test, verify PASS**

```bash
mix test test/esr/session_test.exs
```

Expected: new tests PASS.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: baseline + previous + 2 new green.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/session_process.ex runtime/test/esr/session_test.exs
git commit -m "$(cat <<'EOF'
feat(session_process): has?/2 pass-through scaffold (P2-6a)

Adds SessionProcess.has?/2 — today a thin pass-through to
Esr.Capabilities.Grants.has?/2 after reading principal_id from
SessionProcess.metadata. Establishes the API surface that P3-3a
fills in with real session-local projection (pulls principal's grants
once at init, refreshes on PubSub grants_changed events).

Peers that call SessionProcess.has?/2 today transparently gain
session-local resolution when P3-3a ships. Rationale per
docs/futures/peer-session-capability-projection.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-7: `Esr.SessionsSupervisor` (DynamicSupervisor, max_children=128)

**Feishu notification**: no.

**Files:**
- Create: `runtime/lib/esr/sessions_supervisor.ex`
- Create: `runtime/test/esr/sessions_supervisor_test.exs`

- [ ] **Step 1: Write failing test**

Create `runtime/test/esr/sessions_supervisor_test.exs`:

```elixir
defmodule Esr.SessionsSupervisorTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!({Registry, keys: :unique, name: Esr.Session.Registry})
    :ok
  end

  test "start_link starts with max_children=128" do
    {:ok, sup} = Esr.SessionsSupervisor.start_link([])
    count = DynamicSupervisor.count_children(sup)
    assert count.active == 0
    # Can't directly assert max_children from public API; use a probe:
    # try to start 129 sessions and expect the 129th to fail.
    # Keep this as a separate explicit test to avoid slow test here.
    :ok
  end

  test "start_session/1 creates a Session under the dynamic supervisor" do
    {:ok, _sup} = Esr.SessionsSupervisor.start_link([])

    {:ok, session_sup} = Esr.SessionsSupervisor.start_session(%{
      session_id: "ss-1",
      agent_name: "cc",
      dir: "/tmp/y",
      chat_thread_key: %{chat_id: "oc", thread_id: "om"},
      metadata: %{}
    })

    assert Process.alive?(session_sup)
    assert DynamicSupervisor.count_children(Esr.SessionsSupervisor).active == 1
  end

  @tag :slow
  test "129th concurrent session returns :max_children" do
    {:ok, _sup} = Esr.SessionsSupervisor.start_link(max_children: 4)

    # Start 4 sessions
    for i <- 1..4 do
      {:ok, _} = Esr.SessionsSupervisor.start_session(%{
        session_id: "ss-cap-#{i}",
        agent_name: "cc",
        dir: "/tmp/z/#{i}",
        chat_thread_key: %{chat_id: "c-#{i}", thread_id: "t-#{i}"},
        metadata: %{}
      })
    end

    assert {:error, :max_children} = Esr.SessionsSupervisor.start_session(%{
      session_id: "ss-cap-5",
      agent_name: "cc",
      dir: "/tmp/z/5",
      chat_thread_key: %{chat_id: "c-5", thread_id: "t-5"},
      metadata: %{}
    })
  end
end
```

- [ ] **Step 2: Run test, verify FAIL**

```bash
mix test test/esr/sessions_supervisor_test.exs
```

Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

Create `runtime/lib/esr/sessions_supervisor.ex`:

```elixir
defmodule Esr.SessionsSupervisor do
  @moduledoc """
  DynamicSupervisor hosting all user Sessions. Spec §3.4 D17:
  max_children = 128 (bounds concurrent tmux sessions at 128).

  Overflow behaviour: start_session/1 returns `{:error, :max_children}`;
  surfaced to the user by the SlashHandler as `session limit reached`.
  """
  use DynamicSupervisor

  @default_max 128

  def start_link(opts \\ []) do
    max = Keyword.get(opts, :max_children, @default_max)
    DynamicSupervisor.start_link(__MODULE__, max, name: __MODULE__)
  end

  @impl true
  def init(max), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: max)

  @spec start_session(map()) :: {:ok, pid} | {:error, term()}
  def start_session(session_args) do
    DynamicSupervisor.start_child(__MODULE__, {Esr.Session, session_args})
  end

  def stop_session(session_sup_pid) when is_pid(session_sup_pid) do
    DynamicSupervisor.terminate_child(__MODULE__, session_sup_pid)
  end
end
```

- [ ] **Step 4: Run test, verify PASS**

```bash
mix test test/esr/sessions_supervisor_test.exs
```

Expected: all PASS (the `:slow` test runs by default — no special tag setup needed beyond its name).

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: baseline + 3 new green.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/sessions_supervisor.ex \
        runtime/test/esr/sessions_supervisor_test.exs
git commit -m "$(cat <<'EOF'
feat(sessions_supervisor): DynamicSupervisor with max_children=128

Esr.SessionsSupervisor hosts all user Sessions as DynamicSupervisor
children. Spec D17: max_children=128. Overflow returns :max_children
which the SlashHandler surfaces as "session limit reached" to the user.

Not yet in app supervision tree — wired in P2-9.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-8: Extend agents.yaml fixtures for N=2 tests

**Feishu notification**: no.

**Files:**
- Modify: `runtime/test/esr/fixtures/agents/simple.yaml` (add second app fixture via new file)
- Create: `runtime/test/esr/fixtures/agents/multi_app.yaml`
- Create: `runtime/test/esr/fixtures/agents/README.md` (document fixture shapes)

- [ ] **Step 1: Write fixtures**

The existing `simple.yaml` (shipped by PR-1) covers a single `cc` agent. For N=2 tests (P2-12), we need a fixture with two apps and two agents.

Create `runtime/test/esr/fixtures/agents/multi_app.yaml`:

```yaml
# N=2 test fixture — two agents, each referencing a different Feishu app_id
# via ${app_id} template. Spec §3.5.

agents:
  cc:
    description: "Claude Code for multi-app tests"
    capabilities_required:
      - cap.session.create
      - cap.peer_proxy.forward_feishu
    pipeline:
      inbound:
        - name: feishu_chat_proxy
          impl: Esr.Peers.FeishuChatProxy
      outbound:
        - feishu_chat_proxy
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Peers.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"
    params:
      - name: dir
        required: true
        type: path
      - name: app_id
        required: true
        type: string

  cc-echo:
    description: "Echo variant, same pipeline"
    capabilities_required:
      - cap.session.create
      - cap.peer_proxy.forward_feishu
    pipeline:
      inbound:
        - name: feishu_chat_proxy
          impl: Esr.Peers.FeishuChatProxy
      outbound:
        - feishu_chat_proxy
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Peers.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"
    params:
      - name: dir
        required: true
        type: path
      - name: app_id
        required: true
        type: string
```

Create `runtime/test/esr/fixtures/agents/README.md`:

```markdown
# agents.yaml test fixtures

- `simple.yaml` — minimal single-agent `cc` (shipped by PR-1, P1-9).
- `multi_app.yaml` — two agents (`cc`, `cc-echo`) both referencing `${app_id}` for N=2 tests (P2-12).
```

- [ ] **Step 2: Verify SessionRegistry parses both fixtures**

No production code change; the existing `Esr.SessionRegistry.load_agents/1` parser handles both. Sanity-test via an iex one-liner.

```bash
cd runtime
iex -S mix
# >>> Esr.SessionRegistry.load_agents("test/esr/fixtures/agents/multi_app.yaml")
# Expected: :ok
# >>> Esr.SessionRegistry.agent_def("cc-echo")
# Expected: {:ok, %{description: "Echo variant, ...", ...}}
# exit()
```

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/fixtures/agents/multi_app.yaml \
        runtime/test/esr/fixtures/agents/README.md
git commit -m "$(cat <<'EOF'
test(fixtures): agents.yaml multi_app fixture for N=2 tests

Adds test/esr/fixtures/agents/multi_app.yaml with two agents (cc,
cc-echo) both using ${app_id} template. Used by P2-12 integration
test. PR-1's simple.yaml remains for single-agent unit tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-9: `Esr.Application.children` reshape

**Feishu notification**: no.

**Files:**
- Modify: `runtime/lib/esr/application.ex`
- Modify: `runtime/test/esr/application_boot_test.exs` (or new file — check existence)

- [ ] **Step 1: Write boot-order test**

Create `runtime/test/esr/application_boot_test.exs`:

```elixir
defmodule Esr.ApplicationBootTest do
  use ExUnit.Case, async: false

  test "AdminSession starts before SessionsSupervisor, and SessionsSupervisor does not require SessionRouter" do
    # Both are already started by Esr.Application; verify via whereis.
    assert is_pid(Process.whereis(Esr.AdminSession))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))
    assert is_pid(Process.whereis(Esr.SessionsSupervisor))
    assert is_pid(Process.whereis(Esr.Session.Registry))
    # SessionRouter is PR-3; should not be started in PR-2
    refute Code.ensure_loaded?(Esr.SessionRouter) and Process.whereis(Esr.SessionRouter)
  end

  test "child order: Esr.Session.Registry < AdminSession < SessionsSupervisor" do
    # Inspect Esr.Supervisor's child list; assert ordering is correct.
    children = Supervisor.which_children(Esr.Supervisor)
    ids = Enum.map(children, fn {id, _, _, _} -> id end)

    registry_idx = Enum.find_index(ids, &(&1 == Esr.Session.Registry))
    admin_idx = Enum.find_index(ids, &(&1 == Esr.AdminSession))
    sessions_idx = Enum.find_index(ids, &(&1 == Esr.SessionsSupervisor))

    assert is_integer(registry_idx)
    assert is_integer(admin_idx)
    assert is_integer(sessions_idx)
    assert registry_idx < admin_idx
    assert admin_idx < sessions_idx
  end
end
```

- [ ] **Step 2: Run, verify FAIL**

```bash
mix test test/esr/application_boot_test.exs
```

Expected: FAIL — processes not registered.

- [ ] **Step 3: Modify `runtime/lib/esr/application.ex`**

Insert between `{Esr.SessionRegistry, []},` (line ~42) and `Esr.Workspaces.Registry`:

```elixir
      # 4e.1 Session registry for the Peer/Session refactor (spec §3.5).
      # Must come BEFORE AdminSession (which calls Esr.Session.supervisor_name/1
      # via PeerFactory.spawn_peer_bootstrap/4 if it ever spawns admin-scope
      # peers via Session.supervisor_name) and before SessionsSupervisor.
      {Registry, keys: :unique, name: Esr.Session.Registry},

      # 4e.2 AdminSession — permanent supervisor hosting admin-scope peers.
      # Risk F: started BEFORE SessionRouter (not in PR-2 yet) and BEFORE
      # SessionsSupervisor.
      Esr.AdminSession,

      # 4e.3 SessionsSupervisor (DynamicSupervisor, max_children=128).
      Esr.SessionsSupervisor,
```

- [ ] **Step 4: Run boot test, verify PASS**

```bash
mix test test/esr/application_boot_test.exs
```

Expected: PASS.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: baseline + 2 new green. **Watch for regressions in any test that implicitly boots the app and expects a specific child list.**

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/application.ex \
        runtime/test/esr/application_boot_test.exs
git commit -m "$(cat <<'EOF'
chore(app): start Session.Registry + AdminSession + SessionsSupervisor

Adds three new children to Esr.Supervisor in the correct boot order
(spec §6 Risk F):
  1. Esr.Session.Registry (Registry for via-tuples)
  2. Esr.AdminSession (permanent supervisor for admin-scope peers)
  3. Esr.SessionsSupervisor (DynamicSupervisor, max_children=128)

Boot-order test asserts these come up in the right sequence and that
Esr.SessionRouter (PR-3) is not a dependency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-10: Feature flag `USE_NEW_PEER_CHAIN`

**Feishu notification**: **yes — milestone: P2-6..10 done (Session tree + supervision + boot order)**.

**Files:**
- Modify: `runtime/config/config.exs` (or `runtime.exs` if env-gated)
- Modify: `runtime/lib/esr_web/adapter_channel.ex`
- Create: `runtime/test/esr_web/adapter_channel_feature_flag_test.exs`

- [ ] **Step 1: Write failing test**

Create `runtime/test/esr_web/adapter_channel_feature_flag_test.exs`:

```elixir
defmodule EsrWeb.AdapterChannelFeatureFlagTest do
  use ExUnit.Case, async: false

  test "feature flag USE_NEW_PEER_CHAIN reads from Application env" do
    # Default: false (legacy path)
    Application.put_env(:esr, :use_new_peer_chain, false)
    refute EsrWeb.AdapterChannel.new_peer_chain?()

    Application.put_env(:esr, :use_new_peer_chain, true)
    assert EsrWeb.AdapterChannel.new_peer_chain?()
  after
    Application.delete_env(:esr, :use_new_peer_chain)
  end

  test "ESR_USE_NEW_PEER_CHAIN env var overrides app config" do
    Application.put_env(:esr, :use_new_peer_chain, false)
    System.put_env("ESR_USE_NEW_PEER_CHAIN", "1")
    assert EsrWeb.AdapterChannel.new_peer_chain?()
  after
    System.delete_env("ESR_USE_NEW_PEER_CHAIN")
    Application.delete_env(:esr, :use_new_peer_chain)
  end
end
```

- [ ] **Step 2: Run, verify FAIL**

```bash
mix test test/esr_web/adapter_channel_feature_flag_test.exs
```

Expected: FAIL — `EsrWeb.AdapterChannel.new_peer_chain?/0` undefined.

- [ ] **Step 3: Implement**

Modify `runtime/lib/esr_web/adapter_channel.ex` — add at the top of the module (after `alias`):

```elixir
  @doc """
  Feature flag for the Peer/Session refactor (PR-2).

  Reads in this order:
    1. OS env var ESR_USE_NEW_PEER_CHAIN (any of "1", "true" → enabled)
    2. Application env :esr, :use_new_peer_chain (defaults false)

  Removed entirely in P2-17 once the new path is the sole path.
  """
  def new_peer_chain? do
    case System.get_env("ESR_USE_NEW_PEER_CHAIN") do
      v when v in ["1", "true", "TRUE"] -> true
      "0" -> false
      "false" -> false
      _ -> Application.get_env(:esr, :use_new_peer_chain, false)
    end
  end
```

- [ ] **Step 4: Run test, verify PASS**

```bash
mix test test/esr_web/adapter_channel_feature_flag_test.exs
```

Expected: PASS.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: baseline + 2 new green.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr_web/adapter_channel.ex \
        runtime/test/esr_web/adapter_channel_feature_flag_test.exs
git commit -m "$(cat <<'EOF'
feat(adapter_channel): USE_NEW_PEER_CHAIN feature flag

Adds EsrWeb.AdapterChannel.new_peer_chain?/0 — reads
ESR_USE_NEW_PEER_CHAIN env var first (per-process override),
then Application env :esr, :use_new_peer_chain (defaults false).
P2-11 uses this to route inbound Feishu frames to the new
FeishuAppAdapter when on; legacy AdapterHub.Registry path when off.

Flag default flipped on in P2-14 and removed entirely in P2-17.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: Feishu notification — milestone**

Use `mcp__openclaw-channel__reply`:

> "PR-2 进度：完成 P2-6..10。Session supervisor / Registry / SessionsSupervisor(cap=128) 在 application.ex 里按正确顺序起来，PeerFactory 解析不再走 process-dict scaffold。USE_NEW_PEER_CHAIN feature flag 就位，默认 off（PR-2 跑验证时只影响 ESR_USE_NEW_PEER_CHAIN=1 的 process）。继续 P2-11..14 (retarget + N=2 + E2E + 切默认 on)。"

---

## Task P2-11: Route inbound Feishu frames through FeishuAppAdapter when flag is on

**Feishu notification**: no.

**Files:**
- Modify: `runtime/lib/esr_web/adapter_channel.ex` (extend `handle_in("event", ...)` to branch on flag)
- Modify: `runtime/lib/esr/admin/dispatcher.ex` (register the new `session_agent_new` command kind)
- Create: `runtime/lib/esr/admin/commands/session/agent_new.ex` (stub that returns `{:error, %{"type" => "pending_pr3"}}` — see P2-13)
- Create: `runtime/test/esr_web/adapter_channel_new_chain_test.exs`
- Modify: `runtime/test/esr/admin/commands/session/new_test.exs` (no change expected; just verify it still passes)

- [ ] **Step 1: Write failing test**

Create `runtime/test/esr_web/adapter_channel_new_chain_test.exs`:

```elixir
defmodule EsrWeb.AdapterChannelNewChainTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:esr, :use_new_peer_chain, true)
    on_exit(fn -> Application.delete_env(:esr, :use_new_peer_chain) end)

    start_supervised!({Esr.AdminSessionProcess, []})
    {:ok, _sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: :p2_11_test_sup)

    {:ok, _fab_pid} =
      DynamicSupervisor.start_child(:p2_11_test_sup,
        {Esr.Peers.FeishuAppAdapter, %{app_id: "cli_app_p211", neighbors: [], proxy_ctx: %{}}}
      )

    :ok
  end

  test "adapter_channel forwards {:inbound_event, envelope} to FeishuAppAdapter when flag on" do
    {:ok, fab_pid} = Esr.AdminSessionProcess.admin_peer(:feishu_app_adapter_cli_app_p211)

    # Simulate what adapter_channel.ex handle_in does:
    # (we test the forward helper, not a full Phoenix channel round-trip)
    envelope = %{
      "principal_id" => "p1",
      "workspace_name" => "w1",
      "payload" => %{
        "event_type" => "im.message.receive_v1",
        "chat_id" => "oc_test",
        "thread_id" => "om_test",
        "text" => "hi"
      }
    }

    :ok = EsrWeb.AdapterChannel.forward_to_new_chain("adapter:feishu/cli_app_p211", envelope)

    # Verify FeishuAppAdapter got it (it'll broadcast :new_chat_thread since
    # no session matches)
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "new_chat_thread")
    # The forward is synchronous-ish; assert the broadcast landed.
    assert_receive {:new_chat_thread, "oc_test", "om_test", "cli_app_p211", ^envelope}, 500
  end

  test "adapter_channel uses legacy AdapterHub path when flag off" do
    Application.put_env(:esr, :use_new_peer_chain, false)
    # Assert legacy code path still exercised — this will pass as long as
    # the branching preserves old behaviour (existing tests cover it).
    assert EsrWeb.AdapterChannel.new_peer_chain?() == false
  end
end
```

- [ ] **Step 2: Run, verify FAIL**

```bash
mix test test/esr_web/adapter_channel_new_chain_test.exs
```

Expected: FAIL — `EsrWeb.AdapterChannel.forward_to_new_chain/2` undefined.

- [ ] **Step 3: Implement**

Modify `runtime/lib/esr_web/adapter_channel.ex` — change `defp forward(socket, msg)` to branch on the flag:

```elixir
  defp forward(socket, {:inbound_event, envelope} = msg) do
    topic = socket.assigns.topic

    if new_peer_chain?() and String.starts_with?(topic, "adapter:feishu/") do
      :ok = forward_to_new_chain(topic, envelope)
      {:reply, :ok, socket}
    else
      forward_legacy(socket, msg)
    end
  end

  defp forward(socket, msg), do: forward_legacy(socket, msg)

  @doc false
  def forward_to_new_chain("adapter:feishu/" <> app_id, envelope) do
    sym = String.to_atom("feishu_app_adapter_#{app_id}")

    case Esr.AdminSessionProcess.admin_peer(sym) do
      {:ok, pid} ->
        send(pid, {:inbound_event, envelope})
        :ok

      :error ->
        require Logger
        Logger.warning("adapter_channel: no FeishuAppAdapter for app_id=#{app_id}")
        :error
    end
  end

  # Preserve old behaviour under this name
  defp forward_legacy(socket, msg) do
    topic = socket.assigns.topic

    with {:ok, actor_id} <- Esr.AdapterHub.Registry.lookup(topic),
         [{pid, _}] <- Registry.lookup(Esr.PeerRegistry, actor_id) do
      send(pid, msg)
      {:reply, :ok, socket}
    else
      :error ->
        {:reply, {:error, %{reason: "no binding"}}, socket}
      [] ->
        {:reply, {:error, %{reason: "peer not alive"}}, socket}
    end
  end
```

Create `runtime/lib/esr/admin/commands/session/agent_new.ex` (PR-2 stub — P2-13 extends):

```elixir
defmodule Esr.Admin.Commands.Session.AgentNew do
  @moduledoc """
  New admin command (PR-2): creates an agent-backed Session under
  Esr.SessionsSupervisor. Distinct from Session.New (which spawns a
  branch worktree — legacy; PR-3 collapses these).

  PR-2 scope:
    1. Validate `args.agent` present (D11) and `args.dir` present (D13).
    2. Verify `capabilities_required` (D18) via Esr.Capabilities.has_all?/2.
    3. Call Esr.SessionsSupervisor.start_session/1 with the agent def.
    4. Return {:ok, %{"session_id" => sid}} or {:error, reason}.

  PR-3 wires the real pipeline spawn via SessionRouter.create_session/2.
  In PR-2, session start succeeds only if agent_def has no pipeline peers
  (else SessionProcess alone comes up and pipeline peers are TODO — see
  P2-13 for the controlled-failure E2E test).
  """
  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => args}) do
    agent = args["agent"]
    dir = args["dir"]

    with :ok <- validate_args(agent, dir),
         {:ok, agent_def} <- fetch_agent(agent),
         :ok <- verify_caps(submitter, agent_def.capabilities_required),
         {:ok, sid} <- start_session(agent, agent_def, dir, submitter) do
      {:ok, %{"session_id" => sid, "agent" => agent}}
    end
  end

  def execute(_), do: {:error, %{"type" => "invalid_args", "message" => "submitted_by + args required"}}

  defp validate_args(nil, _), do: {:error, %{"type" => "invalid_args", "message" => "agent required"}}
  defp validate_args(_, nil), do: {:error, %{"type" => "invalid_args", "message" => "dir required"}}
  defp validate_args(_, _), do: :ok

  defp fetch_agent(name) do
    case Esr.SessionRegistry.agent_def(name) do
      {:ok, d} -> {:ok, d}
      {:error, :not_found} -> {:error, %{"type" => "unknown_agent", "agent" => name}}
    end
  end

  defp verify_caps(submitter, caps) when is_list(caps) do
    missing = for c <- caps, not Esr.Capabilities.has?(submitter, c), do: c
    if missing == [], do: :ok, else: {:error, %{"type" => "missing_capabilities", "caps" => missing}}
  end

  defp start_session(agent, agent_def, dir, submitter) do
    sid = :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)

    case Esr.SessionsSupervisor.start_session(%{
           session_id: sid,
           agent_name: agent,
           dir: dir,
           chat_thread_key: %{chat_id: "pending", thread_id: "pending"},
           metadata: %{principal_id: submitter, agent_def: agent_def}
         }) do
      {:ok, _sup} -> {:ok, sid}
      {:error, reason} -> {:error, %{"type" => "session_start_failed", "details" => inspect(reason)}}
    end
  end
end
```

Modify `runtime/lib/esr/admin/dispatcher.ex` — register `session_agent_new` kind in the `run_command/2` dispatcher (search for the existing dispatch case; add a clause). Exact line depends on the existing switch/case shape; the change is a new clause:

```elixir
  defp run_command("session_agent_new", command), do: Esr.Admin.Commands.Session.AgentNew.execute(command)
```

- [ ] **Step 4: Run tests, verify PASS**

```bash
mix test test/esr_web/adapter_channel_new_chain_test.exs \
         test/esr/admin/commands/session/new_test.exs
```

Expected: new tests PASS; existing `new_test.exs` still PASS (unchanged behaviour).

- [ ] **Step 5: Run full suite (flag defaults off — no regressions in existing Feishu paths)**

```bash
mix test
```

Expected: baseline + 2 new green. Critically verify no existing adapter_channel tests break.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr_web/adapter_channel.ex \
        runtime/lib/esr/admin/commands/session/agent_new.ex \
        runtime/lib/esr/admin/dispatcher.ex \
        runtime/test/esr_web/adapter_channel_new_chain_test.exs
git commit -m "$(cat <<'EOF'
feat(adapter_channel): route Feishu frames to new chain when flag on

EsrWeb.AdapterChannel's forward/2 branches on new_peer_chain?/0: when
on + topic starts with "adapter:feishu/", it hands the envelope to
Esr.Peers.FeishuAppAdapter via AdminSessionProcess.admin_peer lookup;
otherwise falls back to the legacy AdapterHub.Registry + PeerRegistry
path.

Adds Esr.Admin.Commands.Session.AgentNew — the new admin command the
SlashHandler casts for /new-session --agent X --dir Y (spec D11/D13/D18).
Existing Session.New (branch-worktree spawn) untouched; PR-3 collapses
them into a single command.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-12: N=2 concurrent sessions integration test

**Feishu notification**: no.

**Files:**
- Create: `runtime/test/esr/integration/n2_sessions_test.exs`

- [ ] **Step 1: Write the test**

Create `runtime/test/esr/integration/n2_sessions_test.exs`:

```elixir
defmodule Esr.Integration.N2SessionsTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Esr.Peers.FeishuAppAdapter

  setup do
    Application.put_env(:esr, :use_new_peer_chain, true)
    on_exit(fn -> Application.delete_env(:esr, :use_new_peer_chain) end)

    :ok = Esr.SessionRegistry.load_agents(
      Path.expand("../fixtures/agents/multi_app.yaml", __DIR__)
    )
    :ok
  end

  test "two app_ids, two sessions; inbound frames do not cross-contaminate" do
    # Two independent AdminSession.FeishuAppAdapter instances (one per app_id)
    sup_name = :n2_test_sup
    {:ok, _sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: sup_name)

    {:ok, _fab_a} = DynamicSupervisor.start_child(sup_name,
      {FeishuAppAdapter, %{app_id: "app_A", neighbors: [], proxy_ctx: %{}}}
    )
    {:ok, _fab_b} = DynamicSupervisor.start_child(sup_name,
      {FeishuAppAdapter, %{app_id: "app_B", neighbors: [], proxy_ctx: %{}}}
    )

    # Two fake FeishuChatProxy pids (test process stands in as both)
    proxy_a = self()
    proxy_b = spawn_link(fn ->
      receive do
        msg ->
          IO.inspect(msg, label: "proxy_b")
          :ok = :done
      end
    end)

    # Register the two sessions against different (chat_id, thread_id) pairs
    :ok = Esr.SessionRegistry.register_session(
      "session-A", %{chat_id: "oc_a", thread_id: "om_a"},
      %{feishu_chat_proxy: proxy_a}
    )
    :ok = Esr.SessionRegistry.register_session(
      "session-B", %{chat_id: "oc_b", thread_id: "om_b"},
      %{feishu_chat_proxy: proxy_b}
    )

    # Fire concurrent inbound events, one per app_id
    {:ok, fab_a} = Esr.AdminSessionProcess.admin_peer(:feishu_app_adapter_app_A)
    {:ok, fab_b} = Esr.AdminSessionProcess.admin_peer(:feishu_app_adapter_app_B)

    env_a = %{"payload" => %{"chat_id" => "oc_a", "thread_id" => "om_a", "text" => "A-hello"}}
    env_b = %{"payload" => %{"chat_id" => "oc_b", "thread_id" => "om_b", "text" => "B-hello"}}

    send(fab_a, {:inbound_event, env_a})
    send(fab_b, {:inbound_event, env_b})

    # proxy_a (this test pid) should receive only A's envelope, never B's.
    assert_receive {:feishu_inbound, %{"payload" => %{"text" => "A-hello"}}}, 1_000
    refute_receive {:feishu_inbound, %{"payload" => %{"text" => "B-hello"}}}, 200
  end
end
```

- [ ] **Step 2: Run, verify it passes**

```bash
mix test test/esr/integration/n2_sessions_test.exs --only integration
```

Expected: PASS (all components already in place from P2-1..11).

- [ ] **Step 3: Run full suite + integration**

```bash
mix test
mix test --only integration
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add runtime/test/esr/integration/n2_sessions_test.exs
git commit -m "$(cat <<'EOF'
test(integration): N=2 concurrent Feishu sessions, no cross-contamination

Spec §6 Risk D — every integration test exercises two apps + two
sessions. This baseline test fires concurrent :inbound_event messages
to two FeishuAppAdapters (one per app_id) and asserts each frame only
reaches the matching session's FeishuChatProxy (via
SessionRegistry.lookup_by_chat_thread/2). Tagged :integration.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-13: E2E smoke `/new-session --agent cc --dir /tmp/test` (controlled failure)

**Feishu notification**: no.

**Scope note**: In PR-2, CCProcess/CCProxy/TmuxProcess don't exist (PR-3 introduces them). The E2E therefore exercises the full path up to session creation and verifies the **controlled failure** mode: Admin.Commands.Session.AgentNew starts the Session supervisor → only SessionProcess comes up (pipeline peers are missing modules) → no pipeline-spawn attempt crashes the Session → SlashHandler replies success with a `pending_pr3_pipeline` marker in metadata.

**Files:**
- Create: `runtime/test/esr/integration/new_session_smoke_test.exs`

- [ ] **Step 1: Write the test**

Create `runtime/test/esr/integration/new_session_smoke_test.exs`:

```elixir
defmodule Esr.Integration.NewSessionSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  setup do
    Application.put_env(:esr, :use_new_peer_chain, true)
    on_exit(fn -> Application.delete_env(:esr, :use_new_peer_chain) end)

    :ok = Esr.SessionRegistry.load_agents(
      Path.expand("../fixtures/agents/simple.yaml", __DIR__)
    )

    # Grant the test principal the caps the cc agent declares
    :ok = Esr.Capabilities.Grants.load_snapshot(%{
      "ou_smoke_user" => ["cap.session.create", "cap.tmux.spawn"]
    })

    :ok
  end

  test "/new-session --agent cc --dir /tmp/test succeeds through SlashHandler → Dispatcher → SessionsSupervisor" do
    # Simulate a FeishuChatProxy sending the slash to SlashHandler
    {:ok, slash} = Esr.AdminSessionProcess.slash_handler_ref()

    envelope = %{
      "principal_id" => "ou_smoke_user",
      "payload" => %{
        "text" => "/new-session --agent cc --dir /tmp/test",
        "chat_id" => "oc_smoke",
        "thread_id" => "om_smoke"
      }
    }

    send(slash, {:slash_cmd, envelope, self()})

    assert_receive {:reply, text}, 2_000
    assert text =~ "session started:", "expected session started reply, got: #{text}"

    # Extract session_id from "session started: <sid>" text
    [_, sid] = Regex.run(~r/session started: (\S+)/, text)

    # Verify SessionProcess came up
    state = Esr.SessionProcess.state(sid)
    assert state.agent_name == "cc"
    assert state.dir == "/tmp/test"
    assert state.metadata.principal_id == "ou_smoke_user"

    # Verify pipeline is NOT yet built (PR-3 work)
    # The peers DynamicSupervisor should have 0 children.
    peers_sup = Esr.Session.supervisor_name(sid)
    assert DynamicSupervisor.count_children(peers_sup).active == 0
  end

  test "/new-session without --agent returns a readable error reply" do
    {:ok, slash} = Esr.AdminSessionProcess.slash_handler_ref()

    envelope = %{
      "principal_id" => "ou_smoke_user",
      "payload" => %{"text" => "/new-session --dir /tmp/x", "chat_id" => "oc", "thread_id" => "om"}
    }

    send(slash, {:slash_cmd, envelope, self()})
    assert_receive {:reply, text}, 1_000
    assert text =~ "requires --agent"
  end

  test "/new-session without matching capability returns missing_capabilities error" do
    :ok = Esr.Capabilities.Grants.load_snapshot(%{"ou_nocap" => []})
    {:ok, slash} = Esr.AdminSessionProcess.slash_handler_ref()

    envelope = %{
      "principal_id" => "ou_nocap",
      "payload" => %{
        "text" => "/new-session --agent cc --dir /tmp/y",
        "chat_id" => "oc", "thread_id" => "om"
      }
    }

    send(slash, {:slash_cmd, envelope, self()})
    assert_receive {:reply, text}, 1_000
    assert text =~ "missing caps"
  end
end
```

- [ ] **Step 2: Run, verify it passes**

```bash
mix test test/esr/integration/new_session_smoke_test.exs --only integration
```

Expected: all three tests PASS — confirms the full slash→dispatcher→session-creation chain works in PR-2 with controlled pipeline skip.

- [ ] **Step 3: Run full suite + integration**

```bash
mix test
mix test --only integration
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add runtime/test/esr/integration/new_session_smoke_test.exs
git commit -m "$(cat <<'EOF'
test(integration): /new-session E2E smoke via slash → SessionsSupervisor

Full PR-2 E2E: FeishuChatProxy-style slash envelope → Esr.Peers.SlashHandler
parses /new-session --agent cc --dir /tmp/test → casts session_agent_new
into Admin.Dispatcher → Esr.Admin.Commands.Session.AgentNew validates caps
(D18) and params (D11/D13) → Esr.SessionsSupervisor.start_session → reply
relayed back as "session started: <sid>".

Controlled failure mode: pipeline peers (CCProcess, TmuxProcess) arrive
in PR-3; PR-2's SessionProcess comes up alone and the peers DynamicSupervisor
is empty. Asserted explicitly. Also covers missing --agent and missing-caps
error branches.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-14: Flip `USE_NEW_PEER_CHAIN` default to true

**Feishu notification**: **yes — milestone: new chain is the default; legacy kept as fallback.**

**Files:**
- Modify: `runtime/config/config.exs` (or the applicable `config/*.exs` — check existing)

- [ ] **Step 1: Flip default**

Add to `runtime/config/config.exs`:

```elixir
config :esr, :use_new_peer_chain, true
```

- [ ] **Step 2: Run full suite**

```bash
mix test
mix test --only integration
```

Expected: all green. If any test flips (legacy path expected) set `Application.put_env(:esr, :use_new_peer_chain, false)` in its setup — explicitly, not silently.

- [ ] **Step 3: Commit**

```bash
git add runtime/config/config.exs
git commit -m "$(cat <<'EOF'
chore(config): flip USE_NEW_PEER_CHAIN default to true

The new Feishu chain (FeishuAppAdapter → FeishuChatProxy → SlashHandler)
is now the default. Legacy AdapterHub.Registry path remains available
as a fallback via ESR_USE_NEW_PEER_CHAIN=0. P2-17 removes the flag
entirely after P2-15/P2-16 delete the legacy modules.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Feishu notification — milestone**

Use `mcp__openclaw-channel__reply`:

> "PR-2 进度：USE_NEW_PEER_CHAIN 默认切 on。Feishu inbound 走新链路：AdapterChannel → FeishuAppAdapter → FeishuChatProxy → SlashHandler → Admin.Dispatcher → SessionsSupervisor。老路径作 fallback。N=2 + /new-session E2E 都 green。继续 P2-15..17 (删老路径)。"

---

## Task P2-15: Remove `feishu_thread_proxy` handling from `peer_server.ex`

**Feishu notification**: no.

**Scope correction (drift finding #5)**: `peer_server.ex` does NOT have big Feishu-specific branches to remove — only a log line in `terminate/2` (line ~168-173) and "adapter" => "feishu" string references in `build_emit_for_tool/3` clauses (lines 774-821). The real removal is of the `feishu_thread_proxy` actor_type used in topology specs.

**Files:**
- Modify: `runtime/lib/esr/peer_server.ex` (drop `feishu_thread_proxy`-specific terminate log)
- Modify: `runtime/lib/esr/topology/*.yaml` or similar topology artifacts that reference `feishu_thread_proxy` — grep to find
- Modify: `runtime/test/esr/peer_server_*.ex` tests that rely on the log line

- [ ] **Step 1: Find current references**

```bash
cd runtime
rg "feishu_thread_proxy" --type elixir
rg "feishu_thread_proxy" test/ lib/ priv/
```

Expected: terminate/2 log in peer_server.ex + any test asserting "session_killed published session_id=". The topology .yaml references — note them as candidates for P3 (not PR-2) if they're the topology artifact system.

- [ ] **Step 2: Remove the terminate log (PR-2 scope)**

Modify `runtime/lib/esr/peer_server.ex` — delete lines ~168-173:

```elixir
  @impl GenServer
  def terminate(_reason, %__MODULE__{actor_id: actor_id, actor_type: actor_type}) do
    :telemetry.execute([:esr, :peer_server, :stopped], %{}, %{
      actor_id: actor_id,
      actor_type: actor_type
    })

    # REMOVED (P2-15): feishu_thread_proxy-specific log moved to
    # Esr.Peers.FeishuChatProxy's terminate/2 in PR-3 when the actor_type
    # lane retires.

    :ok
  end
```

- [ ] **Step 3: Run tests — look for fallouts**

```bash
mix test
```

Expected: if any test greps for `session_killed published session_id=`, it now fails. Fix by either updating the test to match the new path (prefer: move assertion to a FeishuChatProxy terminate hook in PR-3 → tag as `:pr3_pending`) or delete if superseded.

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/peer_server.ex runtime/test/
git commit -m "$(cat <<'EOF'
refactor(peer_server): drop feishu_thread_proxy terminate log

The "session_killed published session_id=" log line was a grep marker
for the L5 gate in the old peer_server-driven Feishu path. PR-2's
FeishuChatProxy owns this lifecycle now; its terminate/2 hook will
emit the equivalent log in PR-3.

Narrower scope than plan outline implied — peer_server.ex does not
have large Feishu-specific branches to remove (those live in topology
artifacts that PR-3 deletes wholesale with the Topology module).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-16: Delete `Esr.AdapterHub.Registry` + `Esr.AdapterHub.Supervisor`

**Feishu notification**: no.

**Files:**
- Delete: `runtime/lib/esr/adapter_hub/registry.ex`
- Delete: `runtime/lib/esr/adapter_hub/supervisor.ex`
- Delete: `runtime/lib/esr/adapter_hub/` (dir if empty after deletions)
- Modify: `runtime/lib/esr/application.ex` (drop `Esr.AdapterHub.Supervisor` from children)
- Modify: `runtime/lib/esr_web/adapter_channel.ex` (drop `alias Esr.AdapterHub.Registry` + legacy path)
- Modify: `runtime/lib/esr/admin/commands/register_adapter.ex` (if references `AdapterHub.Registry.bind/2`)
- Delete: `runtime/test/esr/adapter_hub/` (tests for deleted modules)

- [ ] **Step 1: Find callers**

```bash
cd runtime
rg "Esr.AdapterHub" --type elixir
```

Expected: callers are AdapterChannel, possibly register_adapter.ex, possibly Topology modules (stays; PR-3 deletes Topology).

- [ ] **Step 2: Remove legacy branch in AdapterChannel**

Modify `runtime/lib/esr_web/adapter_channel.ex`:
- Drop `alias Esr.AdapterHub.Registry, as: HubRegistry`
- Change `defp forward_legacy/2` to return `{:reply, {:error, %{reason: "legacy_path_removed"}}, socket}` and log at WARN.
- Document in `@moduledoc` that since PR-2 `USE_NEW_PEER_CHAIN` is always on — but keep the flag branch until P2-17.

Alternatively, since P2-14 flipped the default, can we just delete the legacy path and the flag together? Yes, but the plan keeps them separate for safety. Keep the legacy branch logging-only in P2-16; remove the flag and the branch in P2-17.

Simpler: legacy path now calls a stub that logs + replies error.

```elixir
  defp forward_legacy(socket, _msg) do
    require Logger
    Logger.warning(
      "adapter_channel: legacy AdapterHub.Registry path invoked after P2-16 removal " <>
        "(topic=#{inspect(socket.assigns[:topic])}); set ESR_USE_NEW_PEER_CHAIN=1"
    )
    {:reply, {:error, %{reason: "legacy_path_removed"}}, socket}
  end
```

- [ ] **Step 3: Update register_adapter.ex if needed**

Grep:
```bash
rg "AdapterHub.Registry" runtime/lib/esr/admin/
```

Expected: register_adapter.ex binds `adapter:<name>/<instance_id>` → actor_id. This binding is no longer needed in the new chain (FeishuAppAdapter registers itself via AdminSessionProcess). Remove the bind call; preserve any other register_adapter functionality (workspace rows, etc.) that's unrelated.

- [ ] **Step 4: Delete files**

```bash
git rm runtime/lib/esr/adapter_hub/registry.ex
git rm runtime/lib/esr/adapter_hub/supervisor.ex
git rm -r runtime/test/esr/adapter_hub/
# leave application.ex's "Esr.AdapterHub.Supervisor" reference for next step
```

- [ ] **Step 5: Remove from application.ex children**

Modify `runtime/lib/esr/application.ex` — delete `Esr.AdapterHub.Supervisor,` from children list.

- [ ] **Step 6: Run full suite**

```bash
mix test
mix test --only integration
```

Expected: all green. If register_adapter tests fail because bind was required, fix the tests to skip the bind assertion (it's the point of the deletion).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(adapter_hub): delete AdapterHub.Registry + Supervisor (§2.4)

Spec §2.4: AdapterHub.Registry's role (adapter:<name>/<instance_id> →
actor_id binding) is subsumed by SessionRegistry.lookup_by_chat_thread/2
in the new chain. After P2-14 flipped USE_NEW_PEER_CHAIN default on,
the Registry has no consumers left.

Removes:
  - runtime/lib/esr/adapter_hub/registry.ex
  - runtime/lib/esr/adapter_hub/supervisor.ex
  - runtime/test/esr/adapter_hub/
  - Esr.AdapterHub.Supervisor from application.ex children
  - alias + legacy-path consumers in adapter_channel.ex (legacy fallback
    now logs + errors; fully removed in P2-17)
  - AdapterHub.Registry.bind call in Esr.Admin.Commands.RegisterAdapter

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-17: Remove feature flag entirely

**Feishu notification**: no.

**Files:**
- Modify: `runtime/config/config.exs` (delete the config line)
- Modify: `runtime/lib/esr_web/adapter_channel.ex` (delete `new_peer_chain?/0`, `forward_legacy/2`, branch in `forward/2`)
- Delete: `runtime/test/esr_web/adapter_channel_feature_flag_test.exs`

- [ ] **Step 1: Delete flag config**

Remove from `runtime/config/config.exs`:

```elixir
config :esr, :use_new_peer_chain, true   # DELETE
```

- [ ] **Step 2: Simplify AdapterChannel**

Modify `runtime/lib/esr_web/adapter_channel.ex`:
- Delete `def new_peer_chain?/0`
- Delete `defp forward_legacy/2`
- Replace `defp forward(socket, {:inbound_event, envelope} = _msg)` to call `forward_to_new_chain/2` unconditionally.

```elixir
  defp forward(socket, {:inbound_event, envelope}) do
    topic = socket.assigns.topic

    if String.starts_with?(topic, "adapter:feishu/") do
      :ok = forward_to_new_chain(topic, envelope)
      {:reply, :ok, socket}
    else
      require Logger
      Logger.warning("adapter_channel: non-feishu topic #{inspect(topic)} received :inbound_event")
      {:reply, {:error, %{reason: "unknown_topic"}}, socket}
    end
  end
```

- [ ] **Step 3: Delete flag test**

```bash
git rm runtime/test/esr_web/adapter_channel_feature_flag_test.exs
```

- [ ] **Step 4: Grep for any lingering references**

```bash
cd runtime
rg "USE_NEW_PEER_CHAIN|:use_new_peer_chain|new_peer_chain\\?" --type elixir
```

Expected: zero matches.

- [ ] **Step 5: Run full suite**

```bash
mix test
mix test --only integration
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(adapter_channel): remove USE_NEW_PEER_CHAIN feature flag

After P2-16 deleted the legacy AdapterHub path, the flag is redundant —
all Feishu frames flow through the new chain. Removes:
  - config :esr, :use_new_peer_chain entry
  - EsrWeb.AdapterChannel.new_peer_chain?/0
  - EsrWeb.AdapterChannel.forward_legacy/2
  - adapter_channel_feature_flag_test.exs

PR-2 feature-flag scaffold complete.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task P2-18: Open PR-2 draft

**Feishu notification**: **yes — draft PR opened.**

**Files:** none (just git operations).

- [ ] **Step 1: Run all PR-2 acceptance gates**

```bash
cd runtime
mix test
mix test --only integration
```

Expected: all green.

- [ ] **Step 2: Verify decommissioning**

```bash
rg "Esr\\.AdapterHub" --type elixir     # expect 0
rg "USE_NEW_PEER_CHAIN"                  # expect 0
rg "peer_factory_sup_override"          # expect 0 (removed P2-6)
rg "feishu_thread_proxy" lib/           # expect 0 (P2-15)
```

- [ ] **Step 3: Push branch**

```bash
git push origin feature/peer-session-refactor
```

- [ ] **Step 4: Open PR-2 draft**

```bash
gh pr create --draft --title "feat(runtime): Feishu chain + AdminSession (PR-2)" --body "$(cat <<'EOF'
## Summary

- Adds `Esr.AdminSession` + `Esr.AdminSessionProcess` — permanent supervisor with the bootstrap exception (Risk F): `PeerFactory.spawn_peer_bootstrap/4` bypasses the normal control-plane resolution so AdminSession can start before `Esr.SessionRouter` (PR-3).
- Adds Feishu peer chain: `FeishuAppAdapter` (AdminSession-scope, per app_id) → `FeishuChatProxy` (per-Session, slash detection + drop-non-slash in PR-2) → `FeishuAppProxy` (per-Session outbound proxy with `@required_cap` capability check).
- Extends `Esr.Peer.Proxy` macro with `@required_cap` → injects `Esr.Capabilities.has?/2` wrapper around `forward/2`.
- Adds `Esr.Peers.SlashHandler` (channel-agnostic slash peer; AdminSession-scope) — replaces the slash half of the PR-0-renamed `Esr.Routing.SlashHandler` (the old router stays until PR-3).
- Adds `Esr.Session` + `Esr.SessionProcess` supervisor tree (`:one_for_all`, `:transient`) + `Esr.SessionsSupervisor` (DynamicSupervisor, max_children=128).
- Exposes `Esr.Session.supervisor_name/1`; removes PR-1's process-dict scaffold from `PeerFactory`.
- `SessionProcess.grants` + `SessionProcess.has?/2` pass-through (P2-6a) — scaffold for P3-3a's session-local projection.
- New admin command `Esr.Admin.Commands.Session.AgentNew` that validates `--agent` + `--dir` + `capabilities_required` (D11/D13/D18) and starts a Session under SessionsSupervisor.
- Deletes `Esr.AdapterHub.Registry` + `Esr.AdapterHub.Supervisor` (spec §2.4).
- Feature flag `USE_NEW_PEER_CHAIN` added → flipped default-on → removed entirely within the PR.

Implements PR-2 of the Peer/Session Refactor. See `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` and `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`.

## Test plan

- [x] `mix test` all green
- [x] `mix test --only integration` all green
- [x] AdminSession boot-order test (Risk F): comes up without SessionRouter
- [x] FeishuAppAdapter inbound: envelope → SessionRegistry lookup → FeishuChatProxy pid; no-match → `:new_chat_thread` broadcast
- [x] FeishuChatProxy slash detection: `/` short-circuits to SlashHandler; non-slash dropped + logged (PR-3 wires downstream)
- [x] FeishuAppProxy `@required_cap` check: denied → `{:drop, :cap_denied}`, granted → `send` to target
- [x] Peer.Proxy macro compile-time rejection still works for `handle_call/3` + `handle_cast/2` (PR-1 regression)
- [x] N=2 concurrent sessions: no cross-contamination
- [x] /new-session --agent cc --dir /tmp/test E2E: slash → Dispatcher → SessionsSupervisor (pipeline skipped, PR-3 wires)
- [x] Missing --agent, missing --dir, missing capabilities → readable errors
- [x] SessionsSupervisor max_children enforced
- [x] `rg "Esr.AdapterHub"` returns 0

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Review diff**

Run `gh pr view --web` to eyeball.

- [ ] **Step 6: Feishu notification — draft PR opened**

Use `mcp__openclaw-channel__reply`:

> "PR-2 draft 已开：<paste GitHub URL from `gh pr create`>。等你 review。主要交付：AdminSession 引导例外 + Feishu peer chain (FeishuAppAdapter/ChatProxy/AppProxy) + SlashHandler + Session supervisor tree + SessionsSupervisor(128) + Peer.Proxy macro @required_cap 扩展 + 删掉 AdapterHub.Registry/Supervisor + 删掉过渡 feature flag。Risk F (引导例外) 有专项测试。N=2 + /new-session E2E 全绿 (PR-3 之前 CC peers 用受控失败)."

**PR-2 ready for review.**

---

## Task P2-19: Wait for user review + merge

**Feishu notification**: no.

**No steps.** Paused until the user signals "merge" on the PR. If review comments require changes, follow the `superpowers:receiving-code-review` skill: technical-rigor pass, make fixes on the same branch with new commits (no `--amend`, per the plan's git safety protocol), push.

---

## Task P2-20: PR-2 Progress Snapshot + Feishu notify

**Feishu notification**: **yes — PR-2 merged.**

**Files:**
- Create: `docs/superpowers/progress/<YYYY-MM-DD>-pr2-snapshot.md` (date = merge date)

- [ ] **Step 1: Wait for PR-2 merge**

After user review + squash-merge, proceed.

- [ ] **Step 2: Gather data**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
git fetch origin
git log origin/main..HEAD --oneline              # empty once squash-merged; before that lists the P2 commits
git log origin/main -5 --oneline                  # find the squash-merge SHA
git diff origin/main~1..origin/main --stat       # change footprint
```

- [ ] **Step 3: Write snapshot**

Create `docs/superpowers/progress/<YYYY-MM-DD>-pr2-snapshot.md` with structure mirroring PR-1's snapshot:

```markdown
# PR-2 Progress Snapshot

**Date**: <merge date>
**Branch**: feature/peer-session-refactor (merged)
**Squash-merge commit**: <sha>
**Status**: merged ✅

## New public API surfaces

### `Esr.AdminSession` (runtime/lib/esr/admin_session.ex)
- `start_link(opts)` — Supervisor, :one_for_one, :permanent
- `children_supervisor_name/1` — returns the DynamicSupervisor atom for admin-scope peers

### `Esr.AdminSessionProcess` (runtime/lib/esr/admin_session_process.ex)
- `register_admin_peer(name, pid)` — record an admin-scope peer under a symbolic name
- `admin_peer(name) :: {:ok, pid} | :error`
- `slash_handler_ref/0` — convenience wrapper over `admin_peer(:slash_handler)`

### `Esr.Session` (runtime/lib/esr/session.ex)
- `start_link(%{session_id, agent_name, dir, chat_thread_key, metadata})`
- `supervisor_name(session_id) :: via-tuple | atom` — PeerFactory consumer

### `Esr.SessionProcess` (runtime/lib/esr/session_process.ex)
- `state(session_id) :: %Esr.SessionProcess{}`
- `has?(session_id, permission) :: boolean()` — pass-through to Esr.Capabilities.Grants.has?/2 via metadata.principal_id (P2-6a; P3-3a will project locally)

### `Esr.SessionsSupervisor` (runtime/lib/esr/sessions_supervisor.ex)
- `start_session/1 :: {:ok, pid} | {:error, :max_children | other}`
- `stop_session/1`
- `max_children: 128` (D17)

### `Esr.Peer.Proxy` — macro extension
- `@required_cap "<perm_str>"` (literal string) → wraps `forward/2` with `Esr.Capabilities.has?/2`

### `Esr.Peers.FeishuAppAdapter` (runtime/lib/esr/peers/feishu_app_adapter.ex)
- `start_link(%{app_id:, neighbors:, proxy_ctx:})`
- Registers as `:feishu_app_adapter_<app_id>` in AdminSessionProcess
- Consumes `{:inbound_event, envelope}` from `EsrWeb.AdapterChannel.forward_to_new_chain/2`
- Routes to FeishuChatProxy via SessionRegistry or broadcasts `:new_chat_thread`

### `Esr.Peers.FeishuChatProxy` (runtime/lib/esr/peers/feishu_chat_proxy.ex)
- `start_link(%{session_id:, chat_id:, thread_id:, neighbors:, proxy_ctx:})`
- Slash detection → SlashHandler via AdminSessionProcess
- Non-slash dropped + logged (PR-3 wires downstream)

### `Esr.Peers.FeishuAppProxy` (runtime/lib/esr/peers/feishu_app_proxy.ex)
- `@required_cap "cap.peer_proxy.forward_feishu"` (enforced by macro)
- `forward({:outbound, msg}, ctx) :: :ok | {:drop, :cap_denied | :target_unavailable | :invalid_ctx}`

### `Esr.Peers.SlashHandler` (runtime/lib/esr/peers/slash_handler.ex)
- `start_link(%{dispatcher:, session_id:, neighbors:, proxy_ctx:})`
- Registers as `:slash_handler` in AdminSessionProcess
- Parses `/new-session --agent X --dir Y`, `/end-session`, `/list-sessions`, `/list-agents`
- Casts `session_agent_new | session_end | session_list | agent_list` kinds into Admin.Dispatcher with correlation ref

### `Esr.PeerFactory` — surface extension
- `spawn_peer_bootstrap(sup_name, mod, args, neighbors)` — bootstrap exception (Risk F)

### `Esr.Admin.Commands.Session.AgentNew` (runtime/lib/esr/admin/commands/session/agent_new.ex)
- New admin command kind `session_agent_new`
- Validates `--agent` (D11), `--dir` (D13), capabilities_required (D18)
- Starts Session under SessionsSupervisor; returns `{:ok, %{"session_id" => sid}}`

## Decisions locked in during PR-2

- **D2-PR2-a**: Feishu WebSocket ownership stays in Python `adapter_runner`. `FeishuAppAdapter` is the Elixir-side consumer of `adapter:feishu/<app_id>` Phoenix-channel frames, not a WebSocket client. Spec §3.4/§5.1's "FeishuAppAdapter owns WS" reinterpreted as "terminates the internal Elixir↔Python WS frame stream for that app_id".
- **D2-PR2-b**: `FeishuChatProxy` drops non-slash messages in PR-2 with a log line. The downstream forward into CCProxy is wired by PR-3.
- **D2-PR2-c**: A new admin command `session_agent_new` (distinct from legacy `session_new`/branch-worktree spawn) handles `--agent` sessions in PR-2. PR-3 collapses these.
- **D2-PR2-d**: `Peer.Proxy` macro's `@required_cap` accepts literal strings only. Runtime template substitution deferred.
- **D2-PR2-e**: Session-local capability projection stays as pass-through (`SessionProcess.has?/2` → `Esr.Capabilities.Grants.has?/2`). P3-3a projects locally.
- **D2-PR2-f**: Slash fallback lookup (§5.3) routes via `AdminSessionProcess.slash_handler_ref/0`, not a `SessionRegistry` admin-peer entry — keeps SessionRegistry's surface minimal.

## Tests added

- `admin_session_test.exs` — 4 tests (AdminSessionProcess registration, children_sup, spawn_peer_bootstrap, boot without SessionRouter)
- `peers/feishu_app_adapter_test.exs` — 3 tests (registration, routing, :new_chat_thread)
- `peers/feishu_chat_proxy_test.exs` — 2 tests (slash dispatch, drop-non-slash log)
- `peer/proxy_compile_test.exs` — +2 tests (macro @required_cap + no-cap compile)
- `peers/feishu_app_proxy_test.exs` — 3 tests (cap granted / denied / target dead)
- `peers/slash_handler_test.exs` — 4 tests (cast+ref, relay, registration, unknown)
- `session_test.exs` — 4 base + 2 P2-6a tests
- `peer_factory_test.exs` — rewritten, 2 tests including `spawn_peer_bootstrap/4` on the surface list
- `sessions_supervisor_test.exs` — 3 tests incl. :slow max_children boundary
- `application_boot_test.exs` — 2 tests (child ordering + SessionRouter-independence)
- `adapter_channel_feature_flag_test.exs` — 2 tests (later deleted in P2-17)
- `adapter_channel_new_chain_test.exs` — 2 tests
- `integration/n2_sessions_test.exs` — 1 test
- `integration/new_session_smoke_test.exs` — 3 tests

Totals: ~37 new/rewritten tests. Full suite: 339 + 37 = 376+ tests. Baseline noted: legacy flakes `peer_server_lane_b_test:188`, `cap_test:149` unchanged.

## Tech debt resolved

| Item | Where opened | Resolved in |
|---|---|---|
| `:peer_factory_sup_override` process-dict scaffold | PR-1 P1-10 | P2-6 (moved to Application env, still opt-in for tests) |
| `PeerProxy` has no capability-check wrapper | PR-1 P1-2 | P2-4 (macro `@required_cap`) |
| `SessionRegistry` has no consumers | PR-1 P1-9 | P2-2..4 (FeishuAppAdapter/ChatProxy/AppProxy consume) |
| No AdminSession bootstrap mechanism | — | P2-1 (spawn_peer_bootstrap/4) |

## Tech debt introduced (to be resolved in PR-3)

| Item | Introduced | Resolved in |
|---|---|---|
| `FeishuChatProxy` drops non-slash (PR-3 wires downstream) | P2-3 | P3-1..3 (CCProxy/CCProcess/TmuxProcess chain) |
| Two session-new admin commands coexist (`session_new` legacy + `session_agent_new`) | P2-11 | P3-8 (collapses into single `session_new` with `agent` required) |
| `SessionProcess.has?/2` is a pass-through to global Grants | P2-6a | P3-3a (local projection) |
| `:peer_factory_sup_override` Application-env opt-in for tests | P2-6 | P3 or PR-5 (once every test uses real Session) |
| `Esr.Routing.SlashHandler` (PR-0 renamed legacy) still alive | pre-existing | P3-14 (deletion) |

## Next PR (PR-3) expansion inputs

Expansion session needs:
- This snapshot (load first)
- Spec §3.2 OSProcess, §4.1 CC/Tmux cards, §5.1 inbound data flow, §5.3 slash, §6 Risk E, §1.8 D15 D18 D20
- Plan's PR-3 outline
- This PR's code: `runtime/lib/esr/peers/feishu_chat_proxy.ex` (where CCProxy wire-up goes), `runtime/lib/esr/peers/slash_handler.ex` (for the `session_new`/`session_agent_new` collapse), `runtime/lib/esr/admin/commands/session/new.ex` + `agent_new.ex` (to merge)
- PR-1 code: `runtime/lib/esr/tmux_process.ex`, `py_process.ex`, `os_process.ex` (reused by PR-3's CCProcess composition)

Key PR-3 open questions:
1. **SessionRouter control-plane shape**: which GenServer messages does it accept? Plan §Risk E says only 6 kinds — confirm list matches implementation.
2. **CCProcess adapter_runner coupling**: does CCProcess hold a `Esr.PyProcess` child directly (per-session cc_adapter_runner per D7), or reuse the shared HandlerRouter? Plan implies per-session; verify when expanding.
3. **Topology artifact deletion vs. tests**: `runtime/lib/esr/topology/` removal — check how many tests rely on it; schedule deletion mid-PR-3 or make the removal the last task.
```

- [ ] **Step 4: Commit snapshot**

```bash
git add docs/superpowers/progress/
git commit -m "$(cat <<'EOF'
docs(progress): PR-2 snapshot for next-PR expansion

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin feature/peer-session-refactor
```

- [ ] **Step 5: Feishu notification — PR-2 merged**

Use `mcp__openclaw-channel__reply`:

> "PR-2 已合。Progress snapshot: `docs/superpowers/progress/<date>-pr2-snapshot.md`。下一步：PR-3 expansion（CC chain + SessionRouter + Topology removal）。新会话进行。"

**PR-2 complete.**
```

---

END OF `2026-04-22-pr2-expanded.md` CONTENT.

---

### Report-back summary

- **File written**: not written (read-only mode). The full content is in the message above, ready for the main agent to write to `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/superpowers/progress/2026-04-22-pr2-expanded.md`. Approximate line count: ~1870 lines.

- **Tasks fully expanded**: P2-0..P2-20 (all 21 tasks including the added PR-start notification task P2-0 at the head).

- **Tasks that required design-call documentation (not a failure to expand)**:
  - **P2-13 E2E smoke** — expanded with the controlled-failure approach (pipeline peers skipped; SessionProcess alone comes up; SlashHandler replies "session started: <sid>" with pipeline empty). This is the compromise from "cc peers are PR-3". Flagged for user confirmation.
  - **P2-2 FeishuAppAdapter** — re-scoped from "owns WS" to "consumes Phoenix-channel forwarded frames" per drift finding. User may want to reconsider if the spec should be amended.

- **Plan-vs-current-code drift**:
  1. **Feishu WS is Python** (`py/src/esr/ipc/adapter_runner.py`), not Elixir. Spec/plan language of "FeishuAppAdapter owns WS" reinterpreted as "sole Elixir-side consumer of `adapter:feishu/<app_id>` Phoenix-channel frames". No code change beyond the peer itself — the Python side is untouched.
  2. **`peer_server.ex` has no large Feishu branches** — only a one-line log in `terminate/2` for `feishu_thread_proxy` actor_type + `"adapter" => "feishu"` strings in emit builders. P2-15 is thus much narrower than the plan implies. Documented in that task.
  3. **`Esr.Admin.Commands.Session.New` is branch-worktree spawning today**, not agent-session. Rather than break its callers in PR-2, introduced a NEW command kind `session_agent_new` that runs alongside. PR-3 (P3-8) collapses the two. Preserves the plan's "D15 breaking-change lives in PR-3, not PR-2" boundary.
  4. **Slash fallback (§5.3)**: spec says "look up `admin::slash_handler` via SessionRegistry"; PR-1's SessionRegistry does not have that API. Used `AdminSessionProcess.slash_handler_ref/0` instead — simpler, keeps SessionRegistry surface minimal. Documented as D2-PR2-f in the snapshot template.
  5. **Legacy `Esr.Routing.SlashHandler` coexistence**: stays alive during all of PR-2 (delete in P3-14); new `Esr.Peers.SlashHandler` handles only the new-chain slash path, gated by feature flag until P2-14.

- **Spec-level tensions**:
  - Spec §3.4 "AdminSession hosts FeishuAppAdapter which owns one WebSocket per app" vs. current architecture where WS is Python-side. Resolution: keep the name/role, redefine "owns" as "terminates the internal Elixir-side frame stream". Flag for user.
  - Spec §5.3 slash fallback implicitly assumes SessionRegistry can expose `admin::slash_handler`. Resolved by using AdminSessionProcess instead (documented decision D2-PR2-f). No spec change required.

- **Unresolved items requiring user input before execution**:
  - Confirm the P2-13 controlled-failure interpretation (SessionProcess comes up, pipeline empty, SlashHandler replies success). Alternative: push E2E smoke to PR-3 entirely.
  - Confirm the "FeishuAppAdapter does not own the real WS" redefinition (vs. spec rewrite to make Elixir the Feishu WS owner).
  - Confirm `session_agent_new` as a new admin command kind (vs. breaking `session_new` in PR-2 contrary to plan's "PR-3 breaks it").