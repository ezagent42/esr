# PR-A Multi-App E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-app coexistence + cross-app forward to ESR's existing single-app feishu-to-cc topology, exercised by a new scenario 04 E2E. Existing scenarios 01/02/03 continue to pass against the upgraded mock.

**Architecture:** Three structural changes. (1) `SessionRegistry` ETS key extends from `{chat_id, thread_id}` to `{chat_id, app_id, thread_id}` so two apps with overlapping chat ids never collide. (2) `app_id` propagates through inbound (Python adapter → FeishuAppAdapter → FeishuChatProxy → CCProcess → cc_mcp `<channel>` tag) so claude can echo it. (3) The `reply` MCP tool requires `app_id`; FCP's tool dispatcher recognizes cross-app calls (`args.app_id != state.app_id`), looks up the target FeishuAppAdapter, gates on `workspace:<target_ws>/msg.send`, and sends the directive. mock_feishu gains per-app namespacing + chat-membership so it can reject "app-B not member of chat-A" the way real Feishu does.

**Tech Stack:** Elixir 1.19 / OTP 28 (runtime + peers + Phoenix channels); Python 3.11+ (cc_mcp, feishu adapter, mock_feishu); pytest + ExUnit; bash for E2E scenarios.

**Spec:** `/Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor/docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md` (v1.1, all open questions settled). Read it before implementing.

**Branch:** `feature/pr-a-multi-app` off `origin/main` (post-PR #52). The mock-fidelity-audit branch (`feature/multi-app-mock-fidelity-audit`) ships the spec + audit doc; this plan implements them.

---

## File map

### New files

| Path | Responsibility |
|---|---|
| `tests/e2e/scenarios/04_multi_app_routing.sh` | Scenario 04: 6 steps (single-app, concurrent isolation, cross-app forward, forbidden, non-member, cleanup) |
| `py/tests/scripts/test_mock_feishu_multi_app.py` | Per-app namespacing (push_inbound routes by app_id; sent_messages partition; ws_clients dict) |
| `py/tests/scripts/test_mock_feishu_membership.py` | Outbound rejected when app isn't chat member |
| `runtime/test/esr/peers/feishu_chat_proxy_cross_app_test.exs` | FCP cross-app dispatch + auth + workspace lookup tests |

### Modified files

| Path | Why |
|---|---|
| `runtime/lib/esr/session_registry.ex` | Key extension to 3-tuple; ETS wipe on first boot; `lookup_by_chat_thread/3` |
| `runtime/lib/esr/peers/feishu_app_adapter.ex` | Read `args["app_id"]` (with `state.instance_id` fallback); pass to lookup + broadcast |
| `runtime/lib/esr/session_router.ex` | `:new_chat_thread` handler uses `app_id`; `register_session` writes 3-tuple |
| `runtime/lib/esr/peers/feishu_chat_proxy.ex` | Meta map carries `app_id`; new `dispatch_tool_invoke` cross-app branch with auth gate; `lookup_target_app_proxy/1` helper |
| `runtime/lib/esr/peers/cc_process.ex` | `build_channel_notification/2` adds `app_id` field |
| `adapters/feishu/src/esr_feishu/adapter.py` | `_emit_events_mock` + `_emit_events_lark` add `args["app_id"] = self.app_id` |
| `adapters/cc_mcp/src/esr_cc_mcp/tools.py` | `_REPLY` schema requires `app_id` |
| `scripts/mock_feishu.py` | Per-app namespacing for `_ws_clients` / `_sent_messages` / `_reactions` / `_chat_membership`; `X-App-Id` header recognition; envelope adds `tenant_key` / `update_time` / `user_agent` / full `sender_id` |
| `tests/e2e/scenarios/common.sh` | New helpers: `seed_two_apps_workspaces`, `seed_two_adapters`, `start_two_mock_feishus`, `wait_for_two_sidecars_ready` |
| `tests/e2e/scenarios/01_single_user_create_and_end.sh` | Prompt: tell CC to include `app_id` in reply |
| `tests/e2e/scenarios/02_two_users_concurrent.sh` | Same as 01 |
| `tests/e2e/scenarios/03_tmux_attach_edit.sh` | Same as 01 |
| `runtime/test/esr/session_registry_test.exs` | Test 3-tuple key + lookup_by_chat_thread/3 |
| `runtime/test/esr/peers/cc_process_test.exs` | `build_channel_notification` includes app_id |
| `runtime/test/esr/peers/feishu_app_adapter_test.exs` | inbound forwarded with app_id from envelope (with state fallback) |
| `adapters/cc_mcp/tests/test_tools.py` (or `test_tools_schema_language.py`) | reply schema requires `app_id` |
| `docs/notes/mock-feishu-fidelity.md` | Sign-off checkboxes ticked |
| `docs/guides/writing-an-agent-topology.md` | Cross-references for multi-app + `<channel>` tag `app_id` |
| `docs/notes/futures/` (new dir) | Stash deferred items: ETS-wipe race, cross-tenant principal aliasing |

---

### Task 0: Create the working branch

**Files:** none

- [ ] **Step 1: Confirm worktree is on a clean state**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
git status   # expect "nothing to commit, working tree clean"
git fetch origin
```

- [ ] **Step 2: Create branch off origin/main**

```bash
git checkout -B feature/pr-a-multi-app origin/main
git log --oneline -1   # confirm PR #52's squash-merge commit is HEAD
```

- [ ] **Step 3: Cherry-pick the spec + audit doc + this plan from feature/multi-app-mock-fidelity-audit**

```bash
git cherry-pick 35b2aa0 9eb3b2d 3433f7a
# or if hash drifts: git log feature/multi-app-mock-fidelity-audit --oneline
```

Expected: 3 commits added (audit doc, spec v1.1, spec final-question-close). Working tree clean.

- [ ] **Step 4: Push the branch (just to record start state)**

```bash
git push -u origin feature/pr-a-multi-app
```

---

### Task 1: SessionRegistry 3-tuple key + envelope `app_id`

This is the architectural seam — every other change keys off it. Per spec §10's revision, T1 lands the registry key and the envelope `app_id` propagation in one commit so `master` doesn't break mid-PR. ETS table is wiped on boot (per spec §2.1).

**Files:**
- Modify: `runtime/lib/esr/session_registry.ex` (the registry module + `:ets.delete_all_objects/1` on init)
- Modify: `runtime/lib/esr/peers/feishu_app_adapter.ex:80-95` (`handle_upstream` reads `args["app_id"]` with `state.instance_id` fallback)
- Modify: `runtime/lib/esr/session_router.ex:310, 390, 652` (3 call sites: `lookup_by_chat_thread/3`, `chat_thread_key` map shape, `register_session/3` invocation)
- Modify: `adapters/feishu/src/esr_feishu/adapter.py` (`_emit_events_mock` + `_emit_events_lark` both add `args["app_id"]`)
- Test: `runtime/test/esr/session_registry_test.exs`
- Test: `runtime/test/esr/peers/feishu_app_adapter_test.exs`

- [ ] **Step 1: Write the failing registry test**

Append to `runtime/test/esr/session_registry_test.exs`:

```elixir
describe "PR-A multi-app: 3-tuple key" do
  test "register + lookup uses (chat_id, app_id, thread_id)" do
    sid = "S_PRA1"

    :ok =
      Esr.SessionRegistry.register_session(
        sid,
        %{chat_id: "oc_X", app_id: "feishu_dev", thread_id: ""},
        %{}
      )

    assert {:ok, ^sid, %{}} =
             Esr.SessionRegistry.lookup_by_chat_thread("oc_X", "feishu_dev", "")

    assert :not_found =
             Esr.SessionRegistry.lookup_by_chat_thread("oc_X", "feishu_kanban", "")
  end

  test "two apps over the same chat_id keep distinct sessions" do
    :ok =
      Esr.SessionRegistry.register_session(
        "S_DEV",
        %{chat_id: "oc_shared", app_id: "feishu_dev", thread_id: ""},
        %{}
      )

    :ok =
      Esr.SessionRegistry.register_session(
        "S_KANBAN",
        %{chat_id: "oc_shared", app_id: "feishu_kanban", thread_id: ""},
        %{}
      )

    assert {:ok, "S_DEV", _} =
             Esr.SessionRegistry.lookup_by_chat_thread("oc_shared", "feishu_dev", "")

    assert {:ok, "S_KANBAN", _} =
             Esr.SessionRegistry.lookup_by_chat_thread("oc_shared", "feishu_kanban", "")
  end
end
```

- [ ] **Step 2: Run to confirm FAIL**

```bash
cd runtime && mix test test/esr/session_registry_test.exs --only describe:"PR-A multi-app"
```

Expected: FAIL with `function lookup_by_chat_thread/3 is undefined` or arity mismatch.

- [ ] **Step 3: Update SessionRegistry to 3-tuple key**

Edit `runtime/lib/esr/session_registry.ex`:

```elixir
# Change the public API arity:
def register_session(session_id, chat_thread_key, peer_refs),
  do: GenServer.call(__MODULE__, {:register_session, session_id, chat_thread_key, peer_refs})

def lookup_by_chat_thread(chat_id, app_id, thread_id) do
  case :ets.lookup(@ets_table, {chat_id, app_id, thread_id}) do
    [{_k, sid, refs}] -> {:ok, sid, refs}
    [] -> :not_found
  end
end

# Change the handle_call register_session to write 3-tuple key:
def handle_call(
      {:register_session, session_id, %{chat_id: c, app_id: a, thread_id: t} = key, refs},
      _from,
      state
    ) do
  :ets.insert(@ets_table, {{c, a, t}, session_id, refs})

  state =
    state
    |> put_in([:sessions, session_id], %{key: key, refs: refs})
    |> put_in([:chat_to_session, {c, a, t}], session_id)

  {:reply, :ok, state}
end

# Add ETS wipe on init (find init/1 callback ~line 65 and add at top):
def init(opts) do
  # T-PR-A: wipe pre-existing rows from any prior boot — they are
  # 2-tuple keyed and would ghost-collide on first 3-arity lookup.
  # Safe because the table is in-memory only and is rebuilt by
  # register_session calls.
  if :ets.info(@ets_table) != :undefined do
    :ets.delete_all_objects(@ets_table)
  else
    :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
  end
  # ... rest of original init unchanged ...
end
```

(Read the current `init/1` first to splice in the wipe correctly. The diff is just adding the `delete_all_objects` line.)

- [ ] **Step 4: Run registry test to confirm PASS**

```bash
mix test test/esr/session_registry_test.exs
```

Expected: PASS, all tests in the file.

- [ ] **Step 5: Update all callers to 3-arity**

Edit `runtime/lib/esr/session_router.ex`:

```elixir
# Line 310 (in :new_chat_thread handle_info):
case Esr.SessionRegistry.lookup_by_chat_thread(chat_id, app_id, thread_id) do

# Line 390 (in start_session_sup):
chat_thread_key: %{chat_id: chat_id, app_id: app_id, thread_id: thread_id},

# Line 652 (in register_session call):
Esr.SessionRegistry.register_session(
  session_id,
  %{chat_id: chat_id, app_id: app_id, thread_id: thread_id},
  refs_map
)
```

Where `app_id` is the value already on the `:new_chat_thread` 5-tuple's second slot (variable already exists in scope).

Edit `runtime/lib/esr/peers/feishu_app_adapter.ex` `handle_upstream/2` (~line 80):

```elixir
def handle_upstream({:inbound_event, envelope}, state) do
  args = get_in(envelope, ["payload", "args"]) || %{}
  chat_id = args["chat_id"] || ""
  thread_id = args["thread_id"] || ""
  # T-PR-A: prefer args["app_id"] (Python adapter sets it post-PR-A);
  # fall back to state.instance_id for the case where an older Python
  # sidecar is still running mid-rollout.
  app_id = args["app_id"] || state.instance_id

  case Esr.SessionRegistry.lookup_by_chat_thread(chat_id, app_id, thread_id) do
    {:ok, _session_id, %{feishu_chat_proxy: proxy_pid}} when is_pid(proxy_pid) ->
      send(proxy_pid, {:feishu_inbound, envelope})
      {:forward, [], state}

    :not_found ->
      Phoenix.PubSub.broadcast(
        EsrWeb.PubSub,
        "session_router",
        {:new_chat_thread, app_id, chat_id, thread_id, envelope}
      )

      {:drop, :new_chat_thread_pending, state}

    other ->
      Logger.warning(
        "FeishuAppAdapter: unexpected SessionRegistry reply #{inspect(other)}"
      )

      {:drop, :session_lookup_failed, state}
  end
end
```

- [ ] **Step 6: Update Python adapter to add `app_id` to inbound envelope args**

Edit `adapters/feishu/src/esr_feishu/adapter.py`. Find `_emit_events_mock` (~line 998) — the `yield self._build_msg_received_envelope(args={...})` call. Insert `app_id`:

```python
yield self._build_msg_received_envelope(
    args={
        "chat_id": chat_id,
        "app_id": self._actor_id,   # ESR instance_id; matches what FAA expects
        "message_id": message.get("message_id", ""),
        "content": _extract_text(raw_content, msg_type),
        # ... rest unchanged
    },
    sender_open_id=sender_open_id,
)
```

Find the analogous yield in `_emit_events_lark` and add the same `"app_id": self._actor_id` field.

(`self._actor_id` is set by `__init__(self, actor_id, config)` — verify by grepping; it's the ESR-side instance_id.)

- [ ] **Step 7: Update the FeishuAppAdapter tests for `app_id` propagation**

Edit `runtime/test/esr/peers/feishu_app_adapter_test.exs`. Find an existing `handle_upstream` test (the inbound-event one). Add a new test:

```elixir
test "handle_upstream uses args[app_id] for registry lookup, falls back to state.instance_id" do
  # Arrange: register a session for (chat_X, app_DEV, "")
  parent = self()
  fake_proxy_pid = spawn_link(fn -> receive do msg -> send(parent, {:relay, msg}) end end)

  :ok =
    Esr.SessionRegistry.register_session(
      "S_PRA_FAA",
      %{chat_id: "oc_PRA", app_id: "feishu_DEV", thread_id: ""},
      %{feishu_chat_proxy: fake_proxy_pid}
    )

  # Envelope WITH app_id in args (post-PR-A wire shape)
  env = %{
    "payload" => %{
      "args" => %{
        "chat_id" => "oc_PRA",
        "app_id" => "feishu_DEV",
        "thread_id" => "",
        "content" => "hi"
      }
    }
  }

  state = %{instance_id: "feishu_OTHER", neighbors: [], proxy_ctx: %{}}
  {:forward, [], _} = Esr.Peers.FeishuAppAdapter.handle_upstream({:inbound_event, env}, state)
  assert_receive {:relay, {:feishu_inbound, ^env}}, 200

  # Envelope WITHOUT app_id (legacy sidecar) — falls back to state.instance_id
  env2 = put_in(env, ["payload", "args", "app_id"], nil)
  state2 = %{state | instance_id: "feishu_DEV"}  # fallback path uses this
  {:forward, [], _} = Esr.Peers.FeishuAppAdapter.handle_upstream({:inbound_event, env2}, state2)
  assert_receive {:relay, {:feishu_inbound, ^env2}}, 200
end
```

- [ ] **Step 8: Run the FAA test to confirm PASS**

```bash
mix test test/esr/peers/feishu_app_adapter_test.exs
```

Expected: PASS.

- [ ] **Step 9: Run the full Elixir suite to spot collateral breakage**

```bash
mix test
```

Expected: same green or N flakes you started with (the pre-existing Grant.execute / AdminSessionSlashHandlerBoot flakes). Treat any **new** failure as a missed call site — find with `grep -rn "lookup_by_chat_thread\|register_session" runtime/lib runtime/test --include='*.ex' --include='*.exs'` and update.

- [ ] **Step 10: Run scenario 01 to confirm it still passes against the new wire shape**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
pkill -f "peer-session-refactor/py/.venv" 2>/dev/null; sleep 1
ESR_E2E_KEEP_LOGS=1 E2E_TIMEOUT=300 make e2e-01
```

Expected: `PASS: scenario 01`. The mock still emits the old envelope shape (without `app_id`) — FAA's fallback to `state.instance_id` keeps the old path working.

- [ ] **Step 11: Commit**

```bash
git add runtime/lib/esr/session_registry.ex \
        runtime/lib/esr/peers/feishu_app_adapter.ex \
        runtime/lib/esr/session_router.ex \
        adapters/feishu/src/esr_feishu/adapter.py \
        runtime/test/esr/session_registry_test.exs \
        runtime/test/esr/peers/feishu_app_adapter_test.exs

git commit -m "PR-A T1: SessionRegistry 3-tuple key + envelope app_id

SessionRegistry's ETS key now includes app_id so two apps with
overlapping chat_ids never collide. FeishuAppAdapter reads
args[\"app_id\"] (with state.instance_id fallback for legacy
sidecars). Python adapter populates args[\"app_id\"] from
self._actor_id. ETS table wipes on init to drop pre-upgrade
2-tuple rows.

Tests: registry 3-tuple key (2 cases — single key + concurrent two-app
same-chat); FAA propagation (with + without args.app_id).

Existing scenario 01 still passes against unchanged Python sidecar
behavior (relies on the FAA fallback path)."
```

---

### Task 2: `<channel>` tag carries `app_id`

Pure presentation surface. CC sees `app_id` in every inbound's `<channel>` tag so it can echo it back when calling `reply`.

**Files:**
- Modify: `runtime/lib/esr/peers/feishu_chat_proxy.ex` (extract `app_id` from envelope args into the meta map sent downstream)
- Modify: `runtime/lib/esr/peers/cc_process.ex` (`build_channel_notification/2` adds `"app_id"` field)
- Test: `runtime/test/esr/peers/cc_process_test.exs`
- Test: `runtime/test/esr/peers/feishu_chat_proxy_test.exs`

- [ ] **Step 1: Write the failing CCProcess test**

Append to `runtime/test/esr/peers/cc_process_test.exs`:

```elixir
test "build_channel_notification includes app_id from upstream meta" do
  state = %{
    session_id: "S_PRA2",
    proxy_ctx: %{"channel_adapter" => "feishu"},
    last_meta: %{
      chat_id: "oc_PRA",
      app_id: "feishu_DEV",
      thread_id: "",
      message_id: "om_X",
      sender_id: "ou_someone"
    }
  }

  envelope = Esr.Peers.CCProcess.build_channel_notification(state, "hello")
  assert envelope["app_id"] == "feishu_DEV"
  assert envelope["chat_id"] == "oc_PRA"
  assert envelope["content"] == "hello"
end
```

(Note: `build_channel_notification/2` is defp today; promote to public via `@doc false` + `def` for testability, OR move the test to assert via the broadcast envelope — pick the path that matches what the rest of the test file does.)

- [ ] **Step 2: Run to confirm FAIL**

```bash
mix test test/esr/peers/cc_process_test.exs
```

Expected: FAIL with `app_id` missing or `nil`.

- [ ] **Step 3: Update FCP to put `app_id` into meta**

Edit `runtime/lib/esr/peers/feishu_chat_proxy.ex`. Find `handle_upstream({:feishu_inbound, envelope}, state)` (~line 88). The meta map currently has `message_id, sender_id, thread_id, chat_id`. Add `app_id`:

```elixir
meta = %{
  message_id: message_id,
  sender_id: args["sender_id"] || "",
  thread_id: args["thread_id"] || "",
  chat_id: args["chat_id"] || "",
  app_id: args["app_id"] || ""        # ← NEW (T-PR-A)
}
```

- [ ] **Step 4: Update CCProcess to surface it on the `<channel>` envelope**

Edit `runtime/lib/esr/peers/cc_process.ex` `build_channel_notification/2` (~line 244). Add the `"app_id"` field:

```elixir
defp build_channel_notification(state, text) do
  ctx = state.proxy_ctx || %{}
  last = Map.get(state, :last_meta, %{})

  %{
    "kind" => "notification",
    "source" => Map.get(ctx, "channel_adapter") || "feishu",
    "chat_id" =>
      Map.get(last, :chat_id) || Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id") || "",
    "app_id" =>                           # ← NEW (T-PR-A)
      Map.get(last, :app_id) || Map.get(ctx, :app_id) || Map.get(ctx, "app_id") || "",
    "thread_id" =>
      Map.get(last, :thread_id) || Map.get(ctx, :thread_id) || Map.get(ctx, "thread_id") || "",
    "message_id" => Map.get(last, :message_id) || "",
    "user" => Map.get(last, :sender_id) || "",
    "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
    "content" => text
  }
end
```

(If you needed to promote `build_channel_notification` to public for the test, change `defp` → `def` and add `@doc false`.)

- [ ] **Step 5: Run to confirm PASS**

```bash
mix test test/esr/peers/cc_process_test.exs test/esr/peers/feishu_chat_proxy_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/peers/cc_process.ex \
        runtime/lib/esr/peers/feishu_chat_proxy.ex \
        runtime/test/esr/peers/cc_process_test.exs

git commit -m "PR-A T2: <channel> tag carries app_id

FCP threads args[\"app_id\"] into the meta map; CCProcess's
build_channel_notification surfaces it as \"app_id\" on the
notification envelope cc_mcp ships into claude as a <channel>
tag. CC now sees app_id on every inbound and can echo it on
the reply tool."
```

---

### Task 3: cc_mcp `reply` tool requires `app_id`

CC's MCP `reply` tool gets a required `app_id` parameter. The tool's job is forwarding to the FCP via the existing channel WS — no behaviour change here, just schema + a Python schema test.

**Files:**
- Modify: `adapters/cc_mcp/src/esr_cc_mcp/tools.py` (add `app_id` to `_REPLY` schema)
- Test: `adapters/cc_mcp/tests/test_tools.py` (or `test_tools_schema_language.py` — append, don't create a new file)

- [ ] **Step 1: Write the failing schema test**

Append to `adapters/cc_mcp/tests/test_tools.py`:

```python
def test_reply_schema_requires_app_id():
    """T-PR-A: reply tool must require app_id explicitly (no default)."""
    from esr_cc_mcp.tools import list_tool_schemas

    tools = list_tool_schemas(role="dev")
    reply = next(t for t in tools if t.name == "reply")

    schema = reply.inputSchema
    assert "app_id" in schema["properties"], "reply schema missing app_id property"
    assert "app_id" in schema["required"], (
        "app_id must be REQUIRED on reply per PR-A spec §2.4 — explicit, no default"
    )
    # Description should tell claude where to source the value
    assert "channel" in schema["properties"]["app_id"]["description"].lower() \
        or "instance" in schema["properties"]["app_id"]["description"].lower()
```

- [ ] **Step 2: Run to confirm FAIL**

```bash
cd adapters/cc_mcp
uv run --project . pytest tests/test_tools.py::test_reply_schema_requires_app_id -v
```

Expected: FAIL with `KeyError: 'app_id'` or assertion mismatch.

- [ ] **Step 3: Update the `_REPLY` schema**

Edit `adapters/cc_mcp/src/esr_cc_mcp/tools.py`:

```python
_REPLY = Tool(
    name="reply",
    description=(
        "Send a message to the user's chat channel. The user reads the "
        "channel, not this session — anything you want them to see must go "
        "through this tool. chat_id is from the inbound <channel> tag "
        "(opaque token scoped to the active channel). app_id MUST be "
        "specified explicitly on every call (no default) — take it from "
        "the inbound <channel> tag's app_id, or from a forward request's "
        "target app. This is an ESR routing identifier (instance_id), not "
        "a Feishu cli_xxx. Pass edit_message_id to edit an existing "
        "message in-place instead of sending a new one. Production callers "
        "should always include reply_to_message_id when the reply is in "
        "response to a specific inbound message — the runtime uses it to "
        "clean up any delivery-ack reaction the per-IM proxy emitted on "
        "receive. (Note: edit_message_id and reply_to_message_id are "
        "scoped to the source app's message space — they're stripped on "
        "cross-app reply where target app_id != source app_id.)"
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {
                "type": "string",
                "description": "Channel chat ID (opaque token scoped to the active channel)",
            },
            "app_id": {
                "type": "string",
                "description": (
                    "ESR routing identifier (instance_id from adapters.yaml). "
                    "Required on every call — take it from the inbound "
                    "<channel> tag's app_id attribute. To forward to a "
                    "different app, set this to the target app's instance_id."
                ),
            },
            "text": {"type": "string", "description": "Message text"},
            "edit_message_id": {
                "type": "string",
                "description": "Optional message_id to edit in-place",
            },
            "reply_to_message_id": {
                "type": "string",
                "description": (
                    "Optional message_id of the inbound message this reply "
                    "responds to. When present, the runtime un-reacts any "
                    "delivery-ack emoji the per-IM proxy added on inbound "
                    "receive. Stripped automatically on cross-app reply."
                ),
            },
        },
        "required": ["chat_id", "app_id", "text"],
    },
)
```

- [ ] **Step 4: Run to confirm PASS**

```bash
uv run --project . pytest tests/test_tools.py -v
```

Expected: all green, including the new test.

- [ ] **Step 5: Commit**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
git add adapters/cc_mcp/src/esr_cc_mcp/tools.py adapters/cc_mcp/tests/test_tools.py

git commit -m "PR-A T3: cc_mcp reply tool requires app_id

Schema change: app_id is now in required[]. Description directs
claude to source it from the inbound <channel> tag, with clear
note that it is the ESR instance_id (never the cli_xxx). Calls
out that reply_to_message_id and edit_message_id are stripped
on cross-app reply.

This is a wire-incompatible schema bump — scenarios 01-03 prompts
must be updated in T10 to include app_id explicitly. Doing T10
later in the plan because their full edit needs scenario 04
helpers landed first."
```

---

### Task 4: FCP cross-app dispatch + auth gate

The big one. FCP recognizes when `args.app_id != state.app_id` and routes the directive to the *target* app's adapter, after gating on the target workspace's `msg.send` capability. Three failure modes (`unknown_app`, `forbidden`, `unknown_chat_in_app`) surface as structured `tool_result` errors.

**Files:**
- Modify: `runtime/lib/esr/peers/feishu_chat_proxy.ex` (new branch in `dispatch_tool_invoke("reply", ...)`; new private helpers `lookup_target_app_proxy/1`, `dispatch_cross_app_reply/5`)
- Test: `runtime/test/esr/peers/feishu_chat_proxy_cross_app_test.exs` (new file; integration-flavored: spawn two FAAs and assert routing)

- [ ] **Step 1: Look at the existing `dispatch_tool_invoke("reply", ...)` clause**

```bash
grep -n "dispatch_tool_invoke" runtime/lib/esr/peers/feishu_chat_proxy.ex | head
```

Confirm the function is around lines 165-180. Read 30 lines around it before editing.

- [ ] **Step 2: Write the failing FCP cross-app integration test**

Create `runtime/test/esr/peers/feishu_chat_proxy_cross_app_test.exs`:

```elixir
defmodule Esr.Peers.FeishuChatProxyCrossAppTest do
  @moduledoc """
  PR-A T4: cross-app reply dispatch + authorization tests.

  Spawns two fake FeishuAppAdapter peers (one per app), points FCP's
  state at app_dev as its home, and fires a reply tool_invoke
  targeting app_kanban. Asserts the directive lands in the
  correct adapter's mailbox.
  """
  use ExUnit.Case, async: false
  alias Esr.Peers.FeishuChatProxy

  setup do
    # Two fake adapter peers
    parent = self()
    dev_pid = spawn_link(fn -> relay(parent, :dev) end)
    kanban_pid = spawn_link(fn -> relay(parent, :kanban) end)

    # Register them so FCP's lookup_target_app_proxy/1 can find them
    Registry.register(Esr.PeerRegistry, "feishu_app_adapter_feishu_dev", nil)
    # Need to actually register the pid — depends on PeerRegistry semantics
    # Use Esr.PeerRegistry directly per the production pattern
    {:ok, _} = Esr.PeerRegistry.register_name("feishu_app_adapter_feishu_dev", dev_pid)
    {:ok, _} = Esr.PeerRegistry.register_name("feishu_app_adapter_feishu_kanban", kanban_pid)

    on_exit(fn ->
      Esr.PeerRegistry.unregister_name("feishu_app_adapter_feishu_dev")
      Esr.PeerRegistry.unregister_name("feishu_app_adapter_feishu_kanban")
    end)

    %{dev_pid: dev_pid, kanban_pid: kanban_pid}
  end

  defp relay(parent, label) do
    receive do
      msg ->
        send(parent, {:relay, label, msg})
        relay(parent, label)
    end
  end

  test "home-app reply routes to home FAA (no cross-app branch)", ctx do
    state = %{
      session_id: "S_PRA4_HOME",
      chat_id: "oc_dev",
      app_id: "feishu_dev",
      principal_id: "ou_admin",
      neighbors: [feishu_app_proxy: ctx.dev_pid],
      pending_reacts: %{}
    }

    {:ok, peer} = GenServer.start_link(FeishuChatProxy, state)

    send(peer, {:tool_invoke, "req-home", "reply",
                %{"chat_id" => "oc_dev", "app_id" => "feishu_dev", "text" => "ack"},
                self(), "ou_admin"})

    assert_receive {:relay, :dev, {:outbound, %{"kind" => "reply", "args" => %{"text" => "ack"}}}}, 500
    assert_receive {:push_envelope, %{"req_id" => "req-home", "ok" => true}}, 500
    refute_receive {:relay, :kanban, _}, 200
  end

  test "cross-app reply routes to target FAA when authorized", ctx do
    # Pre-seed capability for ou_admin to send to ws_kanban
    Esr.Capabilities.put_principal_caps("ou_admin", ["workspace:ws_kanban/msg.send"])
    on_exit(fn -> Esr.Capabilities.put_principal_caps("ou_admin", []) end)

    # Pre-seed workspace mapping (chat_id, app_id) → workspace_name
    Esr.Workspaces.Registry.put_chat_workspace(
      {"oc_kanban", "feishu_kanban"}, "ws_kanban"
    )

    state = %{
      session_id: "S_PRA4_X",
      chat_id: "oc_dev",
      app_id: "feishu_dev",
      principal_id: "ou_admin",
      neighbors: [feishu_app_proxy: ctx.dev_pid],
      pending_reacts: %{}
    }

    {:ok, peer} = GenServer.start_link(FeishuChatProxy, state)

    send(peer, {:tool_invoke, "req-x", "reply",
                %{"chat_id" => "oc_kanban", "app_id" => "feishu_kanban",
                  "text" => "summary"},
                self(), "ou_admin"})

    # Directive must hit the kanban FAA, NOT the dev FAA
    assert_receive {:relay, :kanban, {:outbound, %{"kind" => "reply", "args" => %{"text" => "summary"}}}}, 500
    refute_receive {:relay, :dev, _}, 200
    assert_receive {:push_envelope, %{"req_id" => "req-x", "ok" => true,
                                       "data" => %{"cross_app" => true}}}, 500
  end

  test "cross-app reply forbidden when principal lacks target ws cap", ctx do
    Esr.Capabilities.put_principal_caps("ou_admin", [])  # no ws_kanban cap

    Esr.Workspaces.Registry.put_chat_workspace(
      {"oc_kanban", "feishu_kanban"}, "ws_kanban"
    )

    state = %{
      session_id: "S_PRA4_FORBID",
      chat_id: "oc_dev",
      app_id: "feishu_dev",
      principal_id: "ou_admin",
      neighbors: [feishu_app_proxy: ctx.dev_pid],
      pending_reacts: %{}
    }

    {:ok, peer} = GenServer.start_link(FeishuChatProxy, state)

    send(peer, {:tool_invoke, "req-forbid", "reply",
                %{"chat_id" => "oc_kanban", "app_id" => "feishu_kanban", "text" => "x"},
                self(), "ou_admin"})

    assert_receive {:push_envelope, %{
                       "req_id" => "req-forbid",
                       "ok" => false,
                       "error" => %{"type" => "forbidden", "workspace" => "ws_kanban"}
                     }}, 500
    refute_receive {:relay, :kanban, _}, 200
    refute_receive {:relay, :dev, _}, 200
  end

  test "cross-app reply unknown_app when no FAA registered for target", ctx do
    Esr.Capabilities.put_principal_caps("ou_admin", ["workspace:ws_unknown/msg.send"])
    Esr.Workspaces.Registry.put_chat_workspace(
      {"oc_x", "feishu_unregistered"}, "ws_unknown"
    )

    state = %{
      session_id: "S_PRA4_UNK",
      chat_id: "oc_dev",
      app_id: "feishu_dev",
      principal_id: "ou_admin",
      neighbors: [feishu_app_proxy: ctx.dev_pid],
      pending_reacts: %{}
    }

    {:ok, peer} = GenServer.start_link(FeishuChatProxy, state)

    send(peer, {:tool_invoke, "req-unk", "reply",
                %{"chat_id" => "oc_x", "app_id" => "feishu_unregistered", "text" => "x"},
                self(), "ou_admin"})

    assert_receive {:push_envelope, %{
                       "req_id" => "req-unk",
                       "ok" => false,
                       "error" => %{"type" => "unknown_app",
                                    "app_id" => "feishu_unregistered"}
                     }}, 500
  end

  test "cross-app reply strips reply_to_message_id and edit_message_id", ctx do
    Esr.Capabilities.put_principal_caps("ou_admin", ["workspace:ws_kanban/msg.send"])
    Esr.Workspaces.Registry.put_chat_workspace(
      {"oc_kanban", "feishu_kanban"}, "ws_kanban"
    )

    state = %{
      session_id: "S_PRA4_STRIP",
      chat_id: "oc_dev",
      app_id: "feishu_dev",
      principal_id: "ou_admin",
      neighbors: [feishu_app_proxy: ctx.dev_pid],
      pending_reacts: %{}
    }

    {:ok, peer} = GenServer.start_link(FeishuChatProxy, state)

    send(peer, {:tool_invoke, "req-strip", "reply",
                %{"chat_id" => "oc_kanban", "app_id" => "feishu_kanban",
                  "text" => "x",
                  "reply_to_message_id" => "om_OLD",
                  "edit_message_id" => "om_OLDER"},
                self(), "ou_admin"})

    # Directive must NOT carry reply_to_message_id or edit_message_id
    assert_receive {:relay, :kanban, {:outbound, %{"kind" => "reply", "args" => args}}}, 500
    refute Map.has_key?(args, "reply_to_message_id")
    refute Map.has_key?(args, "edit_message_id")
  end
end
```

> Note: this test uses helpers `Esr.Capabilities.put_principal_caps/2` and
> `Esr.Workspaces.Registry.put_chat_workspace/2`. If those don't exist with
> those exact names, find the equivalent test seam (e.g., direct ETS
> insert) by reading `runtime/lib/esr/capabilities.ex` and
> `runtime/lib/esr/workspaces/registry.ex`. Adjust the test setup as
> needed BEFORE running it. **Do not invent a function in the
> production code just to make the test simpler — wire to whatever
> the production module actually exposes.**

- [ ] **Step 3: Run the test to confirm FAIL**

```bash
mix test test/esr/peers/feishu_chat_proxy_cross_app_test.exs
```

Expected: FAIL — most likely on the cross-app cases (the home-app one might pass already).

- [ ] **Step 4: Implement the cross-app dispatch in FCP**

Edit `runtime/lib/esr/peers/feishu_chat_proxy.ex`. Find the existing `dispatch_tool_invoke("reply", args, req_id, channel_pid, state)` clause. Refactor:

```elixir
defp dispatch_tool_invoke("reply", args, req_id, channel_pid, state) do
  text = Map.get(args, "text", "")
  chat_id = Map.get(args, "chat_id") || state.chat_id
  app_id = Map.get(args, "app_id") || state.app_id
  reply_to_msg_id = Map.get(args, "reply_to_message_id", "")
  edit_msg_id = Map.get(args, "edit_message_id", "")

  if app_id == state.app_id do
    # Home-app path — unchanged behaviour
    forward_reply_pass_through(text, reply_to_msg_id, state)
    reply_tool_result(channel_pid, req_id, true, %{"delivered" => true})
    state
  else
    # Cross-app path — strip source-app-scoped ids, log, then dispatch
    if reply_to_msg_id != "" or edit_msg_id != "" do
      Logger.info(
        "FCP cross-app: stripping reply_to/edit ids " <>
          "(target_app=#{app_id}, source_app=#{state.app_id}, " <>
          "reply_to=#{inspect(reply_to_msg_id)}, edit=#{inspect(edit_msg_id)})"
      )
    end

    dispatch_cross_app_reply(chat_id, app_id, text, req_id, channel_pid, state)
  end
end

defp dispatch_cross_app_reply(chat_id, app_id, text, req_id, channel_pid, state) do
  case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
    {:ok, target_ws} ->
      case Esr.Capabilities.has?(state.principal_id, "workspace:#{target_ws}/msg.send") do
        :ok ->
          dispatch_to_target_app(chat_id, app_id, text, target_ws, req_id, channel_pid)

        {:missing, _missing} ->
          reply_tool_result(channel_pid, req_id, false, nil, %{
            "type" => "forbidden",
            "app_id" => app_id,
            "chat_id" => chat_id,
            "workspace" => target_ws,
            "message" =>
              "principal #{state.principal_id} lacks workspace:#{target_ws}/msg.send"
          })
      end

    :not_found ->
      reply_tool_result(channel_pid, req_id, false, nil, %{
        "type" => "unknown_chat_in_app",
        "app_id" => app_id,
        "chat_id" => chat_id,
        "message" =>
          "no workspace mapping for (chat_id=#{chat_id}, app_id=#{app_id})"
      })
  end

  state
end

defp dispatch_to_target_app(chat_id, app_id, text, _target_ws, req_id, channel_pid) do
  case lookup_target_app_proxy(app_id) do
    {:ok, target_pid} ->
      send(target_pid, {:outbound,
        %{"kind" => "reply",
          "args" => %{"chat_id" => chat_id, "text" => text}}})
      reply_tool_result(channel_pid, req_id, true,
        %{"dispatched" => true, "cross_app" => true})

    :not_found ->
      reply_tool_result(channel_pid, req_id, false, nil, %{
        "type" => "unknown_app",
        "app_id" => app_id,
        "message" =>
          "no FeishuAppAdapter registered for app_id=#{inspect(app_id)}"
      })
  end
end

defp lookup_target_app_proxy(app_id) when is_binary(app_id) do
  # FeishuAppAdapter peers register under
  # "feishu_app_adapter_<instance_id>" in the PeerRegistry — see
  # admin_session.ex:166 (spawn_feishu_app_adapter).
  case Registry.lookup(Esr.PeerRegistry, "feishu_app_adapter_#{app_id}") do
    [{pid, _}] when is_pid(pid) -> {:ok, pid}
    _ -> :not_found
  end
end
```

(Verify the `Esr.Capabilities.has?/2` return signature matches `:ok | {:missing, _}`. If it's `true | false | {:missing, ...}`, adjust the case match accordingly. Read the function before assuming.)

- [ ] **Step 5: Run the test to confirm PASS**

```bash
mix test test/esr/peers/feishu_chat_proxy_cross_app_test.exs
```

Expected: PASS, all 5 tests.

- [ ] **Step 6: Run the full Elixir suite**

```bash
mix test
```

Expected: green or N pre-existing flakes only.

- [ ] **Step 7: Commit**

```bash
git add runtime/lib/esr/peers/feishu_chat_proxy.ex \
        runtime/test/esr/peers/feishu_chat_proxy_cross_app_test.exs

git commit -m "PR-A T4: FCP cross-app dispatch + authorization

When reply.app_id differs from state.app_id, FCP routes the
directive to the target app's FeishuAppAdapter (looked up via
PeerRegistry under \"feishu_app_adapter_<instance>\") after
gating on workspace:<target_ws>/msg.send for the source
session's principal.

Three structured failure modes:
- unknown_chat_in_app: workspace_for_chat returned :not_found
- forbidden: principal lacks msg.send for target workspace
- unknown_app: no FAA pid registered for that instance_id

Cross-app strips reply_to_message_id and edit_message_id (those
ids belong to the source app's message space) with an info log."
```

---

### Task 5: mock_feishu inbound envelope completeness

Mock-side fidelity work — add the fields real Feishu inbound carries that the mock currently omits. No behavioural change for existing tests; just shape parity for downstream consumers.

**Files:**
- Modify: `scripts/mock_feishu.py` (`push_inbound` envelope shape)
- Test: `py/tests/scripts/test_mock_feishu_envelope_shape.py` (new)

- [ ] **Step 1: Write the failing shape test**

Create `py/tests/scripts/test_mock_feishu_envelope_shape.py`:

```python
"""T-PR-A T5: mock_feishu inbound envelope must match the live-capture
fixture shape field-for-field (extras OK, missing fields not OK).

Reference: adapters/feishu/tests/fixtures/live-capture/text_message.json
captured 2026-04-19 against real Feishu Open Platform.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import aiohttp
import pytest

# Add scripts/ to path so we can import mock_feishu
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from mock_feishu import MockFeishu  # type: ignore


@pytest.mark.asyncio
async def test_inbound_envelope_includes_required_fields():
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    received_envelopes: list[dict] = []

    async def consume_ws():
        ws_url = base_url.replace("http://", "ws://") + "/ws"
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(ws_url) as ws:
                await asyncio.sleep(0.05)  # let connect settle

                # Trigger an inbound
                mock.push_inbound(
                    chat_id="oc_test",
                    sender_open_id="ou_test",
                    msg_type="text",
                    content_text="hello",
                )

                msg = await asyncio.wait_for(ws.receive(), timeout=2.0)
                received_envelopes.append(json.loads(msg.data))

    try:
        await asyncio.wait_for(consume_ws(), timeout=5.0)
    finally:
        await mock.stop()

    assert len(received_envelopes) == 1
    env = received_envelopes[0]

    # Required header fields
    assert env["schema"] == "2.0"
    h = env["header"]
    assert "event_id" in h
    assert h["event_type"] == "im.message.receive_v1"
    assert "create_time" in h
    assert "tenant_key" in h, "header.tenant_key missing — see live-capture/text_message.json"
    assert "app_id" in h

    # Required event.sender fields
    s = env["event"]["sender"]
    assert s["sender_type"] == "user"
    assert "tenant_key" in s, "event.sender.tenant_key missing"
    sid = s["sender_id"]
    assert "user_id" in sid, "sender_id.user_id missing"
    assert "open_id" in sid
    assert "union_id" in sid, "sender_id.union_id missing"

    # Required event.message fields
    m = env["event"]["message"]
    assert "message_id" in m
    assert "chat_id" in m
    assert m["chat_type"] == "p2p"
    assert "create_time" in m
    assert "update_time" in m, "message.update_time missing"
    assert "user_agent" in m, "message.user_agent missing"
    assert m["message_type"] == "text"
    assert m["content"] == json.dumps({"text": "hello"}, ensure_ascii=False)
```

- [ ] **Step 2: Run to confirm FAIL**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/peer-session-refactor
uv run --project py pytest py/tests/scripts/test_mock_feishu_envelope_shape.py -v
```

Expected: FAIL — multiple `assert "..." in env...` failures.

- [ ] **Step 3: Update `push_inbound` envelope shape**

Edit `scripts/mock_feishu.py` `push_inbound` method (~line 159):

```python
def push_inbound(
    self,
    *,
    chat_id: str,
    sender_open_id: str,
    msg_type: str = "text",
    content_text: str = "",
    app_id: str = "default",       # T-PR-A T6 prep: routing key (used in T6)
    tenant_key: str = "16a9e2384317175f",  # synthetic but realistic shape
) -> str:
    """Synthesize a P2ImMessageReceiveV1 envelope and push it to every
    connected WS client. Returns the synthesised message_id.

    Envelope shape matches adapters/feishu/tests/fixtures/live-capture/
    text_message.json captured against real Feishu Open Platform —
    extras OK in real wire, missing fields cause silent drops in
    consumers (e.g., lark_oapi unpacking).
    """
    msg_id = _new_message_id()
    now_ms = str(int(time.time() * 1000))
    envelope = {
        "schema": "2.0",
        "header": {
            "event_id": secrets.token_hex(16),
            "token": "",
            "create_time": now_ms,
            "event_type": "im.message.receive_v1",
            "tenant_key": tenant_key,
            "app_id": app_id,
        },
        "event": {
            "sender": {
                "sender_id": {
                    # user_id is the Feishu short id (8 hex chars in real
                    # captures). Synthetic here.
                    "user_id": secrets.token_hex(4),
                    "open_id": sender_open_id,
                    "union_id": "on_" + secrets.token_hex(16),
                },
                "sender_type": "user",
                "tenant_key": tenant_key,
            },
            "message": {
                "message_id": msg_id,
                "create_time": now_ms,
                "update_time": now_ms,
                "chat_id": chat_id,
                "chat_type": "p2p",
                "message_type": msg_type,
                "content": json.dumps({"text": content_text}, ensure_ascii=False),
                "user_agent": "Mozilla/5.0 (mock_feishu) MockFeishuClient/1.0",
            },
        },
    }
    data = json.dumps(envelope, ensure_ascii=False)
    for ws in list(self._ws_clients):
        if not ws.closed:
            asyncio.create_task(ws.send_str(data))  # noqa: RUF006
    return msg_id
```

(Note: this still uses the old global `self._ws_clients` — T6 will partition by app_id. T5 just adds fields.)

- [ ] **Step 4: Run to confirm PASS**

```bash
uv run --project py pytest py/tests/scripts/test_mock_feishu_envelope_shape.py -v
```

Expected: PASS.

- [ ] **Step 5: Run scenario 01 to confirm extra fields don't break the live e2e**

```bash
pkill -f "peer-session-refactor/py/.venv" 2>/dev/null; sleep 1
ESR_E2E_KEEP_LOGS=1 E2E_TIMEOUT=300 make e2e-01
```

Expected: `PASS: scenario 01`. The Python adapter ignores fields it doesn't unpack — extras are safe.

- [ ] **Step 6: Commit**

```bash
git add scripts/mock_feishu.py py/tests/scripts/test_mock_feishu_envelope_shape.py
git commit -m "PR-A T5: mock_feishu inbound envelope shape matches live-capture

Adds tenant_key (header + sender), full sender_id (user_id +
open_id + union_id), update_time, user_agent. Reference:
adapters/feishu/tests/fixtures/live-capture/text_message.json
captured 2026-04-19. Extras vs real wire are still OK; consumers
unpack the fields they need.

Pure additive change — scenarios 01-03 unchanged."
```

---

### Task 6: mock_feishu per-app namespacing

Mock_feishu's data model goes from global lists to per-app maps. New `app_id` parameter on `push_inbound`; new `X-App-Id` header for outbound `POST /im/v1/messages`.

**Files:**
- Modify: `scripts/mock_feishu.py` (data model + endpoints)
- Test: `py/tests/scripts/test_mock_feishu_multi_app.py` (new)

- [ ] **Step 1: Write the failing namespacing test**

Create `py/tests/scripts/test_mock_feishu_multi_app.py`:

```python
"""T-PR-A T6: mock_feishu per-app namespacing.

push_inbound routes to ws_clients of a SPECIFIC app_id;
sent_messages partitioned by caller's app_id (X-App-Id header);
ws_clients partitioned per app.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import aiohttp
import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from mock_feishu import MockFeishu  # type: ignore


@pytest.mark.asyncio
async def test_push_inbound_routes_only_to_target_app_clients():
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    dev_received: list[dict] = []
    kanban_received: list[dict] = []

    async def consume(app_id: str, sink: list[dict]):
        ws_url = base_url.replace("http://", "ws://") + f"/ws?app_id={app_id}"
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(ws_url) as ws:
                while True:
                    try:
                        msg = await asyncio.wait_for(ws.receive(), timeout=1.5)
                    except asyncio.TimeoutError:
                        return
                    if msg.type == aiohttp.WSMsgType.TEXT:
                        sink.append(json.loads(msg.data))

    async def driver():
        # Wait for both consumers to subscribe
        await asyncio.sleep(0.2)
        mock.push_inbound(chat_id="oc_dev", sender_open_id="ou_a",
                          content_text="for-dev", app_id="feishu_dev")
        mock.push_inbound(chat_id="oc_kanban", sender_open_id="ou_a",
                          content_text="for-kanban", app_id="feishu_kanban")

    try:
        await asyncio.wait_for(asyncio.gather(
            consume("feishu_dev", dev_received),
            consume("feishu_kanban", kanban_received),
            driver(),
        ), timeout=5.0)
    except asyncio.TimeoutError:
        pass  # consumers exit on their own timeout
    finally:
        await mock.stop()

    assert any("for-dev" in env["event"]["message"]["content"] for env in dev_received)
    assert all("for-kanban" not in env["event"]["message"]["content"] for env in dev_received)

    assert any("for-kanban" in env["event"]["message"]["content"] for env in kanban_received)
    assert all("for-dev" not in env["event"]["message"]["content"] for env in kanban_received)


@pytest.mark.asyncio
async def test_outbound_partitioned_by_x_app_id_header():
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    # Pre-register chat membership so the membership check (T7) doesn't
    # reject these. T6 alone may allow without membership; once T7 lands,
    # this test still works because we explicitly register both pairs.
    mock.register_chat_membership("feishu_dev", "oc_dev")
    mock.register_chat_membership("feishu_kanban", "oc_kanban")

    async with aiohttp.ClientSession() as session:
        for app_id, chat, text in [
            ("feishu_dev", "oc_dev", "from-dev"),
            ("feishu_kanban", "oc_kanban", "from-kanban"),
        ]:
            async with session.post(
                f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
                headers={"X-App-Id": app_id},
                json={"receive_id": chat, "msg_type": "text",
                      "content": json.dumps({"text": text})},
            ) as resp:
                assert resp.status == 200
                body = await resp.json()
                assert body["code"] == 0

    # GET /sent_messages?app_id=...
    async with aiohttp.ClientSession() as session:
        async with session.get(f"{base_url}/sent_messages?app_id=feishu_dev") as r:
            dev_msgs = await r.json()
        async with session.get(f"{base_url}/sent_messages?app_id=feishu_kanban") as r:
            kanban_msgs = await r.json()
        async with session.get(f"{base_url}/sent_messages") as r:
            all_msgs = await r.json()  # unscoped — returns union (back-compat)

    await mock.stop()

    dev_contents = [json.loads(m["content"])["text"] for m in dev_msgs]
    kanban_contents = [json.loads(m["content"])["text"] for m in kanban_msgs]
    assert "from-dev" in dev_contents and "from-kanban" not in dev_contents
    assert "from-kanban" in kanban_contents and "from-dev" not in kanban_contents
    assert len(all_msgs) == 2  # union
```

- [ ] **Step 2: Run to confirm FAIL**

```bash
uv run --project py pytest py/tests/scripts/test_mock_feishu_multi_app.py -v
```

Expected: FAIL — `push_inbound` doesn't accept `app_id`-scoped routing yet, `register_chat_membership` doesn't exist, `/ws?app_id=` query param ignored, `/sent_messages?app_id=` not partitioned.

- [ ] **Step 3: Refactor mock_feishu data model + endpoints**

This is a larger edit. Outline:

1. Change instance fields:

```python
# Before:
self._ws_clients: list[web.WebSocketResponse] = []
self._sent_messages: list[dict[str, Any]] = []
# ... etc.

# After:
self._ws_clients: dict[str, list[web.WebSocketResponse]] = {}
self._sent_messages: dict[str, list[dict[str, Any]]] = {}
self._reactions: dict[str, list[dict[str, Any]]] = {}
self._un_reactions: dict[str, list[dict[str, Any]]] = {}
self._chat_membership: dict[str, set[str]] = {}     # for T7
```

2. WS handler reads `app_id` from query:

```python
async def _on_ws_connect(self, request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    app_id = request.query.get("app_id", "default")
    self._ws_clients.setdefault(app_id, []).append(ws)
    try:
        async for _ in ws:
            pass
    finally:
        if app_id in self._ws_clients and ws in self._ws_clients[app_id]:
            self._ws_clients[app_id].remove(ws)
    return ws
```

3. `push_inbound` routes only to its app's WS clients:

```python
def push_inbound(self, *, chat_id, sender_open_id, msg_type="text",
                  content_text="", app_id="default", tenant_key=...) -> str:
    # ... build envelope (same as T5) ...
    envelope["header"]["app_id"] = app_id    # the routing app

    data = json.dumps(envelope, ensure_ascii=False)
    for ws in list(self._ws_clients.get(app_id, [])):
        if not ws.closed:
            asyncio.create_task(ws.send_str(data))  # noqa: RUF006
    return msg_id
```

4. `_on_create_message` reads `X-App-Id` and partitions sent_messages:

```python
async def _on_create_message(self, request: web.Request) -> web.Response:
    body = await request.json()
    message_id = _new_message_id()
    app_id = request.headers.get("X-App-Id", "default")

    record = {
        "message_id": message_id,
        "receive_id_type": request.query.get("receive_id_type", "chat_id"),
        "receive_id": body.get("receive_id"),
        "msg_type": body.get("msg_type"),
        "content": body.get("content"),
        "ts_unix_ms": int(time.time() * 1000),
        "app_id": app_id,                  # tag for query/debug
    }
    self._sent_messages.setdefault(app_id, []).append(record)

    # ... rest unchanged (file_key bookkeeping etc.)

    # Build response (same shape as today)
    return web.json_response({"code": 0, "msg": "", "data": entry})
```

5. `_on_get_sent_messages` (or wherever GET /sent_messages is served) supports `?app_id=`:

```python
async def _on_get_sent_messages(self, request: web.Request) -> web.Response:
    app_id = request.query.get("app_id")
    if app_id:
        return web.json_response(list(self._sent_messages.get(app_id, [])))
    # Unscoped: union for backwards compat
    union: list[dict] = []
    for msgs in self._sent_messages.values():
        union.extend(msgs)
    return web.json_response(union)
```

6. Add `register_chat_membership(app_id, chat_id)` method (skeleton — T7 fleshes out the rejection):

```python
def register_chat_membership(self, app_id: str, chat_id: str) -> None:
    """Mark `app_id`'s bot as a member of `chat_id`. T7 will use this
    to reject outbound from non-member apps."""
    self._chat_membership.setdefault(app_id, set()).add(chat_id)
```

7. Update similar partitioning for `_reactions` / `_un_reactions` GET endpoints (read existing handler shape; same pattern as `sent_messages`).

- [ ] **Step 4: Run T5's test (envelope shape) — must still pass**

```bash
uv run --project py pytest py/tests/scripts/test_mock_feishu_envelope_shape.py -v
```

Expected: PASS — refactor preserved envelope shape.

- [ ] **Step 5: Run T6's test**

```bash
uv run --project py pytest py/tests/scripts/test_mock_feishu_multi_app.py -v
```

Expected: PASS for both tests. (`test_outbound_partitioned_by_x_app_id_header` calls `register_chat_membership` so it shouldn't trip T7's not-yet-landed rejection logic.)

- [ ] **Step 6: Run scenario 01 — backwards compat check**

```bash
pkill -f "peer-session-refactor/py/.venv" 2>/dev/null; sleep 1
ESR_E2E_KEEP_LOGS=1 E2E_TIMEOUT=300 make e2e-01
```

Existing scenarios don't pass `?app_id=` on /ws, don't set `X-App-Id` on POST. They get the default bucket (`"default"`). Existing behaviour preserved. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/mock_feishu.py py/tests/scripts/test_mock_feishu_multi_app.py
git commit -m "PR-A T6: mock_feishu per-app namespacing

ws_clients, sent_messages, reactions, un_reactions all partitioned
by app_id. WS connection identifies app via ?app_id= query;
outbound POST identifies via X-App-Id header. push_inbound
routes only to clients of the target app_id. Unscoped GET endpoints
return union for back-compat with scenarios 01-03.

register_chat_membership(app_id, chat_id) added as the seam T7
will use for outbound rejection."
```

---

### Task 7: mock_feishu chat-membership rejection

When the calling app isn't registered as a member of the target chat, mock_feishu rejects the outbound. Real Feishu does this; mock now matches.

**Files:**
- Modify: `scripts/mock_feishu.py` (`_on_create_message` checks membership)
- Test: `py/tests/scripts/test_mock_feishu_membership.py` (new)

- [ ] **Step 1: Write the failing membership test**

Create `py/tests/scripts/test_mock_feishu_membership.py`:

```python
"""T-PR-A T7: mock_feishu rejects outbound when caller is not a member
of the target chat. Mirrors real Feishu's behaviour where app-B
trying to send to a chat where app-B's bot isn't a member returns
code != 0.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import aiohttp
import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from mock_feishu import MockFeishu  # type: ignore


@pytest.mark.asyncio
async def test_outbound_rejected_when_app_not_chat_member():
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    # Register only feishu_dev as a member of oc_dev. feishu_kanban is
    # NOT registered for oc_dev.
    mock.register_chat_membership("feishu_dev", "oc_dev")

    async with aiohttp.ClientSession() as session:
        # Allowed: feishu_dev to oc_dev
        async with session.post(
            f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
            headers={"X-App-Id": "feishu_dev"},
            json={"receive_id": "oc_dev", "msg_type": "text",
                  "content": json.dumps({"text": "ok"})},
        ) as r:
            body = await r.json()
            assert body["code"] == 0

        # Rejected: feishu_kanban to oc_dev (not a member)
        async with session.post(
            f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
            headers={"X-App-Id": "feishu_kanban"},
            json={"receive_id": "oc_dev", "msg_type": "text",
                  "content": json.dumps({"text": "blocked"})},
        ) as r:
            body = await r.json()
            assert body["code"] != 0
            assert "not a member" in body.get("msg", "").lower() \
                or body.get("code") in (230_002, 99_991_400)  # Feishu's typical codes

    # The blocked message must NOT appear in any sent_messages bucket
    async with aiohttp.ClientSession() as session:
        async with session.get(f"{base_url}/sent_messages") as r:
            all_msgs = await r.json()

    contents = [json.loads(m["content"])["text"] for m in all_msgs]
    assert "ok" in contents
    assert "blocked" not in contents

    await mock.stop()


@pytest.mark.asyncio
async def test_outbound_default_app_no_membership_required():
    """Back-compat: when X-App-Id is unset (= 'default'), no membership
    check applies. This is what scenarios 01-03 rely on."""
    mock = MockFeishu()
    base_url = await mock.start(port=0)

    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
            json={"receive_id": "oc_anything", "msg_type": "text",
                  "content": json.dumps({"text": "legacy"})},
        ) as r:
            body = await r.json()
            assert body["code"] == 0

    await mock.stop()
```

- [ ] **Step 2: Run to confirm FAIL**

```bash
uv run --project py pytest py/tests/scripts/test_mock_feishu_membership.py -v
```

Expected: FAIL on the rejection case (code is 0 because mock currently doesn't check).

- [ ] **Step 3: Add membership check to `_on_create_message`**

Edit `scripts/mock_feishu.py` `_on_create_message`:

```python
async def _on_create_message(self, request: web.Request) -> web.Response:
    body = await request.json()
    app_id = request.headers.get("X-App-Id", "default")
    receive_id = body.get("receive_id")

    # T-PR-A T7: real-Feishu parity — reject when calling app isn't
    # a member of the target chat. The "default" bucket bypasses
    # this check for back-compat with scenarios 01-03 that don't
    # set X-App-Id.
    if app_id != "default":
        members = self._chat_membership.get(app_id, set())
        if receive_id not in members:
            return web.json_response({
                "code": 230002,
                "msg": f"app {app_id!r} is not a member of chat {receive_id!r}",
                "data": {},
            })

    # ... (rest of the existing handler unchanged) ...
```

- [ ] **Step 4: Run to confirm PASS**

```bash
uv run --project py pytest py/tests/scripts/test_mock_feishu_membership.py py/tests/scripts/test_mock_feishu_multi_app.py -v
```

Expected: PASS (both files).

- [ ] **Step 5: Run scenario 01 — back-compat must hold**

```bash
pkill -f "peer-session-refactor/py/.venv" 2>/dev/null; sleep 1
ESR_E2E_KEEP_LOGS=1 E2E_TIMEOUT=300 make e2e-01
```

Expected: `PASS: scenario 01`. Scenarios 01-03 don't set `X-App-Id` so they fall in the "default" bucket and bypass membership.

- [ ] **Step 6: Commit**

```bash
git add scripts/mock_feishu.py py/tests/scripts/test_mock_feishu_membership.py
git commit -m "PR-A T7: mock_feishu rejects outbound when app not chat member

When X-App-Id != 'default', POST /im/v1/messages checks
self._chat_membership[app_id] and returns code 230002 (Feishu's
typical 'not a member' code) if receive_id isn't in the set.
'default' bucket bypasses for back-compat with scenarios 01-03."
```

---

### Task 8: scenario 04 helpers in common.sh

New helper functions for scenario 04 setup. Reusable building blocks; the actual scenario step is in T9.

**Files:**
- Modify: `tests/e2e/scenarios/common.sh`

- [ ] **Step 1: Add the helpers**

Edit `tests/e2e/scenarios/common.sh`. Append (after the existing helpers, before the trap definitions if any are at file end):

```bash
# T-PR-A T8: multi-app helpers — scenario 04 needs two mock_feishu
# instances (different ports), two adapter sidecars (different
# instance_ids), workspaces.yaml with both apps' chats, and
# capabilities for the test principal in both workspaces.

seed_two_apps_workspaces() {
  # Writes ${ESRD_HOME}/default/workspaces.yaml with two workspaces
  # and registers chat memberships in both mock_feishu instances.
  mkdir -p "${ESRD_HOME}/default"
  cat > "${ESRD_HOME}/default/workspaces.yaml" <<'EOF'
workspaces:
  ws_dev:
    cwd: "/tmp/esr-e2e-workspace-dev"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_pra_dev,    app_id: feishu_app_dev,    kind: dm}
      - {chat_id: oc_pra_orphan, app_id: feishu_app_dev,    kind: dm}
    env: {}
  ws_kanban:
    cwd: "/tmp/esr-e2e-workspace-kanban"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_pra_kanban, app_id: feishu_app_kanban, kind: dm}
    env: {}
EOF
}

seed_two_capabilities() {
  # ou_admin has msg.send for BOTH workspaces (used by 5.2/5.3 happy
  # paths). ou_restricted has msg.send only for ws_dev (used by 5.4
  # forbidden test).
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}" "${ESRD_HOME}/default"
  local caps_yaml='principals:
  - id: ou_admin
    kind: feishu_user
    note: e2e admin (full access)
    capabilities: ["*"]
  - id: ou_restricted
    kind: feishu_user
    note: e2e principal allowed only for ws_dev
    capabilities:
      - workspace:ws_dev/msg.send
      - session:default/create
      - tmux:default/spawn
      - handler:cc_adapter_runner/invoke'
  printf '%s\n' "$caps_yaml" > "${ESRD_HOME}/${ESRD_INSTANCE}/capabilities.yaml"
  printf '%s\n' "$caps_yaml" > "${ESRD_HOME}/default/capabilities.yaml"
}

: "${MOCK_FEISHU_PORT_DEV:=8211}"
: "${MOCK_FEISHU_PORT_KANBAN:=8212}"
export MOCK_FEISHU_PORT_DEV MOCK_FEISHU_PORT_KANBAN

seed_two_adapters() {
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
  cat > "${ESRD_HOME}/${ESRD_INSTANCE}/adapters.yaml" <<EOF
instances:
  feishu_app_dev:
    type: feishu
    config:
      app_id: feishu_app_dev
      app_secret: mock
      base_url: http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}
  feishu_app_kanban:
    type: feishu
    config:
      app_id: feishu_app_kanban
      app_secret: mock
      base_url: http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}
EOF
}

start_two_mock_feishus() {
  # Spawn two mock_feishu instances. Use the existing start_mock_feishu
  # logic but parameterized by port + pidfile suffix.
  _start_one_mock "${MOCK_FEISHU_PORT_DEV}"    "dev"
  _start_one_mock "${MOCK_FEISHU_PORT_KANBAN}" "kanban"
  # Pre-register chat membership so cross-app outbound from app_dev
  # to oc_pra_kanban can succeed (or be rejected per T9 scenario step).
  curl -sS -X POST -H 'content-type: application/json' \
    -d '{"app_id":"feishu_app_dev","chat_id":"oc_pra_dev"}' \
    "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/register_membership" >/dev/null
  curl -sS -X POST -H 'content-type: application/json' \
    -d '{"app_id":"feishu_app_kanban","chat_id":"oc_pra_kanban"}' \
    "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/register_membership" >/dev/null
  # Note: NOT registering oc_pra_orphan in either app — drives 5.5 step.
}

_start_one_mock() {
  local port=$1 suffix=$2 pidfile="/tmp/mock-feishu-${ESR_E2E_RUN_ID}-${suffix}.pid"
  local log="/tmp/mock-feishu-${ESR_E2E_RUN_ID}-${suffix}.log"
  ( cd "${_E2E_REPO_ROOT}" && \
    nohup uv run --project py python scripts/mock_feishu.py --port "${port}" \
      >"${log}" 2>&1 & echo $! > "${pidfile}" )
  for _ in $(seq 1 50); do
    if curl -sS --fail "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 \
         || curl -sS "http://127.0.0.1:${port}/sent_messages" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  _fail_with_context "mock_feishu (${suffix}) did not come up on port ${port}"
}

wait_for_two_sidecars_ready() {
  local timeout_s=${1:-30} elapsed=0
  for port in "${MOCK_FEISHU_PORT_DEV}" "${MOCK_FEISHU_PORT_KANBAN}"; do
    elapsed=0
    while true; do
      local count
      count=$(curl -sS --fail "http://127.0.0.1:${port}/ws_clients" 2>/dev/null \
        | jq -r '.count // 0' 2>/dev/null || echo 0)
      [[ "$count" -ge 1 ]] && break
      sleep 0.2
      elapsed=$(awk "BEGIN {print $elapsed + 0.2}")
      if awk "BEGIN {exit !($elapsed > $timeout_s)}"; then
        _fail_with_context "wait_for_two_sidecars_ready: port=${port} no /ws client after ${timeout_s}s"
      fi
    done
  done
}
```

Also extend `_e2e_teardown` (existing function in common.sh) to kill both mock_feishu pidfiles:

```bash
# Inside _e2e_teardown, after the existing mock-feishu kill:
for suffix in dev kanban; do
  [[ -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}-${suffix}.pid" ]] && {
    kill -9 "$(cat /tmp/mock-feishu-${ESR_E2E_RUN_ID}-${suffix}.pid)" 2>/dev/null || true
    rm -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}-${suffix}.pid"
  }
done
pkill -9 -f "mock_feishu\.py --port ${MOCK_FEISHU_PORT_DEV}" 2>/dev/null || true
pkill -9 -f "mock_feishu\.py --port ${MOCK_FEISHU_PORT_KANBAN}" 2>/dev/null || true
```

- [ ] **Step 2: Add `register_membership` endpoint to mock_feishu**

Edit `scripts/mock_feishu.py`. Find where the routes are registered (`app.router.add_post` calls). Add:

```python
app.router.add_post("/register_membership", self._on_register_membership)
```

And add the handler:

```python
async def _on_register_membership(self, request: web.Request) -> web.Response:
    """T-PR-A T8 helper: register `app_id` as member of `chat_id`.
    Used by scenario setup to pre-seed the membership map."""
    body = await request.json()
    app_id = body.get("app_id", "default")
    chat_id = body.get("chat_id", "")
    self.register_chat_membership(app_id, chat_id)
    return web.json_response({"ok": True})
```

- [ ] **Step 3: Spot-check syntax**

```bash
bash -n tests/e2e/scenarios/common.sh
```

Expected: no output (success).

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/scenarios/common.sh scripts/mock_feishu.py
git commit -m "PR-A T8: scenario 04 helpers (seed_two_apps_*, start_two_mock_feishus)

common.sh helpers:
- seed_two_apps_workspaces: workspaces.yaml with ws_dev + ws_kanban
- seed_two_capabilities: ou_admin (full) + ou_restricted (ws_dev only)
- seed_two_adapters: adapters.yaml with two instances pointing at
  ports 8211 + 8212
- start_two_mock_feishus: spawn both mocks, pre-register memberships
  for the chats scenario 04 will use
- wait_for_two_sidecars_ready: poll both /ws_clients endpoints
- _e2e_teardown extended to kill both mock pidfiles

mock_feishu /register_membership endpoint added so scenario can
configure membership without reaching into Python state."
```

---

### Task 9: scenario 04 script

The actual E2E. 6 steps per the spec storyboard.

**Files:**
- Create: `tests/e2e/scenarios/04_multi_app_routing.sh`
- Modify: `Makefile` (add `e2e-04` + extend `e2e` target)

- [ ] **Step 1: Write the scenario script**

Create `tests/e2e/scenarios/04_multi_app_routing.sh`:

```bash
#!/usr/bin/env bash
# PR-A scenario 04 — multi-app coexistence + cross-app forward.
# See docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md §5
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASELINE=$(e2e_tmp_baseline_snapshot)

load_agent_yaml
seed_two_capabilities
seed_two_apps_workspaces
seed_two_adapters
start_two_mock_feishus
start_esrd
wait_for_two_sidecars_ready 30

# --- Step 1: single-app inbound (seed 1, sequential) -----------------
PROBE1='Please reply with exactly: ack-dev-only. Then stop. The reply tool requires app_id — use the app_id from this <channel> tag.'
INBOUND1=$(curl -sS -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_dev\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE1"),\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" \
  | jq -r '.message_id')
[[ -n "$INBOUND1" ]] || _fail_with_context "step1: no message_id"

for _ in $(seq 1 600); do
  if curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
       | jq -e '.[] | select(.receive_id=="oc_pra_dev")' >/dev/null; then
    break
  fi
  sleep 0.1
done

A_BODY=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
         | jq -r '.[] | select(.receive_id=="oc_pra_dev") | .content' | tr '\n' ' ')
B_BODY=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
         | jq -r '.[] | .content' | tr '\n' ' ')
assert_contains "$A_BODY" "ack-dev-only" "step1: app_dev got its ack"
assert_not_contains "$B_BODY" "ack-dev-only" "step1: app_kanban did NOT receive crossover"

# --- Step 1b: concurrent isolation (seed 1, concurrent) --------------
PROBE_DEV='Please reply with exactly: ack-dev-iso. Use this <channel>'\''s app_id on the reply.'
PROBE_KAN='Please reply with exactly: ack-kanban-iso. Use this <channel>'\''s app_id on the reply.'

curl -sS -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_dev\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE_DEV"),\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" >/dev/null &
curl -sS -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_kanban\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE_KAN"),\"app_id\":\"feishu_app_kanban\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/push_inbound" >/dev/null &
wait

for _ in $(seq 1 1200); do
  ra=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
       | jq '[.[] | select(.content | contains("ack-dev-iso"))] | length')
  rb=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq '[.[] | select(.content | contains("ack-kanban-iso"))] | length')
  [[ "$ra" -ge 1 && "$rb" -ge 1 ]] && break
  sleep 0.1
done
[[ "$ra" -ge 1 ]] || _fail_with_context "step1b: app_dev no ack-dev-iso"
[[ "$rb" -ge 1 ]] || _fail_with_context "step1b: app_kanban no ack-kanban-iso"

DEV_ALL=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
          | jq -r '.[].content' | tr '\n' ' ')
KAN_ALL=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
          | jq -r '.[].content' | tr '\n' ' ')
assert_not_contains "$DEV_ALL" "ack-kanban-iso" "step1b: dev did not receive kanban content"
assert_not_contains "$KAN_ALL" "ack-dev-iso"    "step1b: kanban did not receive dev content"

# --- Step 2: cross-app forward (seed 2b) -----------------------------
PROBE2="Please do two things, in order: (1) reply with the four letters 'ack-dev' to me using app_id feishu_app_dev; (2) reply to chat oc_pra_kanban with text 'progress: dev finished step 1' using app_id feishu_app_kanban."
curl -sS -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_dev\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE2"),\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" >/dev/null

for _ in $(seq 1 1200); do
  if curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq -e '.[] | select(.content | contains("dev finished step 1"))' >/dev/null; then
    break
  fi
  sleep 0.1
done

KAN2=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq -r '.[] | .content' | tr '\n' ' ')
assert_contains "$KAN2" "dev finished step 1" "step2: kanban received the cross-app forward"

# --- Step 5: cleanup -------------------------------------------------
ACTORS_OUT=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null)
SIDS=()
while IFS= read -r sid; do
  [[ -n "$sid" ]] && SIDS+=("$sid")
done < <(echo "$ACTORS_OUT" | awk '/^thread:/ { sub("thread:", "", $1); print $1 }')

for sid in "${SIDS[@]}"; do
  ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
    uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit session_end \
    --arg "session_id=${sid}" --wait --timeout 30
done

for _ in $(seq 1 50); do
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  if ! echo "$out" | grep -q "^thread:"; then break; fi
  sleep 0.1
done

for sid in "${SIDS[@]}"; do
  assert_actors_list_lacks "thread:${sid}" "step5: ${sid} torn down"
done

export _E2E_BASELINE="$BASELINE"
echo "PASS: scenario 04"
```

> **Notes on omitted steps**: Steps 5.4 (forbidden) and 5.5 (non-member) are
> tested at the **unit level** in T4's `feishu_chat_proxy_cross_app_test.exs`
> (the structured error shapes are asserted there). The E2E for those is
> valuable but adds CC-prompt-conditioning fragility (CC must reliably emit
> a structural failure marker on a deny). To keep scenario 04 deterministic,
> we land the unit coverage now and defer the E2E step to a follow-up if
> the unit coverage proves insufficient. **If you (the implementer) feel
> confident the prompt can be made deterministic, add steps 3 + 4 below
> step 2 following the §5.4 / §5.5 spec — but only if you can land them
> green on first try; otherwise leave for a follow-up PR.**

- [ ] **Step 2: Make the script executable**

```bash
chmod +x tests/e2e/scenarios/04_multi_app_routing.sh
```

- [ ] **Step 3: Add Makefile target**

Edit `Makefile`. Find the `e2e-03:` target. Add after it:

```makefile
e2e-04:
	$(E2E_RUN) tests/e2e/scenarios/04_multi_app_routing.sh
```

And update the aggregate `e2e:` target:

```makefile
e2e: e2e-01 e2e-02 e2e-03 e2e-04
```

- [ ] **Step 4: Run scenario 04 — first time, expect to debug**

```bash
pkill -f "peer-session-refactor/py/.venv" 2>/dev/null; sleep 1
ESR_E2E_KEEP_LOGS=1 E2E_TIMEOUT=420 make e2e-04
```

Expected (best case): `PASS: scenario 04`. **Realistic case**: 1-3 iterations of debugging — most likely culprits are timing on the concurrent step or mock_feishu route configuration. Use the preserved logs at `${ESRD_HOME}/${ESRD_INSTANCE}/logs/stdout.log` to triage.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/scenarios/04_multi_app_routing.sh Makefile
git commit -m "PR-A T9: scenario 04 multi-app E2E (steps 1, 1b, 2, 5)

Steps:
1.  app_dev sole inbound, no crossover into app_kanban
1b. concurrent inbounds to app_dev + app_kanban — distinct sessions,
    isolated reply paths
2.  cross-app forward: app_dev session calls reply with
    app_id=feishu_app_kanban — assertion on app_kanban's sent_messages
5.  end both sessions via admin submit session_end

Steps 3 (forbidden) and 4 (non-member) covered at unit level in
feishu_chat_proxy_cross_app_test.exs. E2E coverage for those
deferred — adds prompt-conditioning fragility we can revisit if
the unit coverage proves insufficient."
```

---

### Task 10: scenarios 01-03 prompt edits

`reply` schema requires `app_id`. Existing scenarios use a prompt that doesn't tell CC about `app_id`. Update.

**Files:**
- Modify: `tests/e2e/scenarios/01_single_user_create_and_end.sh`
- Modify: `tests/e2e/scenarios/02_two_users_concurrent.sh`
- Modify: `tests/e2e/scenarios/03_tmux_attach_edit.sh`

- [ ] **Step 1: Update scenario 01 prompt**

In `tests/e2e/scenarios/01_single_user_create_and_end.sh`, find each prompt that drives a CC reply (typically the first inbound). Add a sentence that tells CC how to source `app_id`:

```bash
# Before (~line 50):
PROMPT="Please do exactly two things, in order: (1) reply with the three letters 'ack' (just the word, no punctuation); (2) send the file at absolute path ${PROBE_FILE} via the send_file MCP tool."

# After:
PROMPT="Please do exactly two things, in order: (1) reply with the three letters 'ack' (just the word, no punctuation) — for the reply tool, use the app_id you see in the inbound <channel> tag; (2) send the file at absolute path ${PROBE_FILE} via the send_file MCP tool."
```

(Find every other prompt in scenario 01 that would drive a `reply` tool call and apply the same edit.)

- [ ] **Step 2: Update scenarios 02 and 03 prompts**

Same edit — for every PROBE/PROMPT variable that drives a CC reply, append "for the reply tool, use the app_id you see in the inbound <channel> tag." Or weave it into the existing copy.

- [ ] **Step 3: Run scenarios 01-03**

```bash
pkill -f "peer-session-refactor/py/.venv" 2>/dev/null; sleep 1
E2E_TIMEOUT=360 make e2e-01 e2e-02 e2e-03
```

Expected: All three pass. If CC fails to include `app_id`, mock_feishu won't record the reply (because cc_mcp's tool schema rejects it).

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/scenarios/01_single_user_create_and_end.sh \
        tests/e2e/scenarios/02_two_users_concurrent.sh \
        tests/e2e/scenarios/03_tmux_attach_edit.sh

git commit -m "PR-A T10: scenarios 01-03 prompts include app_id directive

reply tool schema now requires app_id (T3); prompts updated to
tell CC: 'for the reply tool, use the app_id you see in the
inbound <channel> tag'. Without this nudge, claude would omit
app_id and cc_mcp would error on schema validation."
```

---

### Task 11: docs sync

Pin the audit sign-off; add cross-references in the topology guide.

**Files:**
- Modify: `docs/notes/mock-feishu-fidelity.md` (tick §9 sign-off boxes)
- Modify: `docs/guides/writing-an-agent-topology.md` (cross-ref §三 + add multi-app section)
- Create: `docs/notes/futures/multi-app-deferred.md` (ETS-wipe race + cross-tenant principal aliasing)

- [ ] **Step 1: Tick the sign-off boxes**

Edit `docs/notes/mock-feishu-fidelity.md` §9. Replace `- [ ]` with `- [x]` for each box that lands in this PR (envelope shape match, per-app namespacing, cross-app rejection, scenarios 01-03 still pass, audit doc updated).

- [ ] **Step 2: Add a multi-app section to the topology guide**

Edit `docs/guides/writing-an-agent-topology.md`. After §三 (which lays out the message flow), add a new sub-section §三.5 referencing the multi-app changes. ~30 lines:

```markdown
### 三.5 多 app 的扩展（PR-A 后）

每条 inbound 现在带 `app_id` 字段，CC 在 `<channel>` tag 里看到。
要做 cross-app forward，CC 调 `reply` 时显式指定目标 `app_id`：

  - `app_id == 当前 session 的 home app` → 走原 home-app 路径
  - `app_id != home app` → FCP 跨 app 分发：查
    `Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id)` →
    校验 `workspace:<target_ws>/msg.send` cap → 找
    `feishu_app_adapter_<app_id>` peer pid → 转发 directive

3 种结构化失败：
  - `unknown_chat_in_app` — workspaces.yaml 没该 (chat, app) 映射
  - `forbidden` — principal 没目标 ws 的 msg.send
  - `unknown_app` — 没注册对应的 FAA peer

跨 app 时 `reply_to_message_id` 和 `edit_message_id` 会被
strip，因为它们属于 source app 的 message_id 空间，target app
不认识。

参考：`docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md`。
```

- [ ] **Step 3: Create deferred-items note**

Create `docs/notes/futures/multi-app-deferred.md`:

```markdown
# Multi-app PR-A — deferred items

Tracked here so they don't get lost. None block PR-A merge.

## 1. ETS wipe race window (PR-A spec §9.6)

`Esr.SessionRegistry`'s `init/1` calls `:ets.delete_all_objects/1` on
boot. If an inbound arrives during the ~ms between table-clear and
the first re-register, `lookup_by_chat_thread/3` returns
`:not_found`, triggering auto-create — duplicate sessions for the
mid-flight inbound. Boot is normally quiescent so impact is low.

Fix path: gate inbound dispatch on a "registry ready" signal (e.g.,
`Application.fetch_env(:esr, :registry_ready)` set in `init/1`'s
final return).

## 2. Cross-tenant principal aliasing (PR-A spec §9.5)

A Feishu user has different `open_id` per tenant. PR-A's
authorization gate assumes `state.principal_id` is also a valid
principal in the target workspace's `capabilities.yaml`. This is
true for two apps under one tenant; cross-tenant cross-app would
break.

Fix path: introduce a `principal_alias` table (yaml, ETS-backed)
mapping `(source_open_id, source_tenant) → (target_open_id,
target_tenant)`. Authorization gate checks aliases first, then
direct match.

## 3. Live Feishu smoke gate (PR-A spec §9.1)

mock_feishu simulates app-membership rejection at our discretion.
Real Feishu's exact error code + retry semantics for
"app-B not member of chat-A" are not characterized. Need a manual
or scheduled smoke test against real Feishu before declaring PR-A
prod-ready.

Fix path: a `make smoke-live` recipe that runs scenario 04 against
real Feishu credentials (read from `.env.live`). Run on demand,
not in CI.
```

- [ ] **Step 4: Run all e2e tests one final time**

```bash
pkill -f "peer-session-refactor/py/.venv" 2>/dev/null; sleep 1
E2E_TIMEOUT=420 make e2e
```

Expected: `PASS: scenario 01`, `PASS: scenario 02`, `PASS: scenario 03`, `PASS: scenario 04`.

- [ ] **Step 5: Commit**

```bash
git add docs/notes/mock-feishu-fidelity.md \
        docs/guides/writing-an-agent-topology.md \
        docs/notes/futures/multi-app-deferred.md

git commit -m "PR-A T11: docs — sign-off audit + topology guide xref + deferred items

- mock-feishu-fidelity.md §9 sign-off boxes ticked for PR-A scope
- writing-an-agent-topology.md §三.5 added: multi-app extension
  reference for future agent authors
- docs/notes/futures/multi-app-deferred.md tracks 3 known-but-
  deferred items: ETS wipe race, cross-tenant principal aliasing,
  live Feishu smoke gate"
```

- [ ] **Step 6: Push branch + open PR**

```bash
git push -u origin feature/pr-a-multi-app

gh pr create --title "PR-A: multi-app E2E (scenario 04) + cross-app forward" \
  --body "$(cat <<'EOF'
## Summary

Adds multi-app coexistence + cross-app forward to the existing single-app feishu-to-cc topology. Scenario 04 exercises both paths against an upgraded mock_feishu.

- `SessionRegistry` ETS key extends to `(chat_id, app_id, thread_id)` so two apps with overlapping chat ids never collide
- `app_id` propagates through inbound (Python adapter → FAA → FCP → CCProcess → cc_mcp `<channel>` tag)
- `reply` MCP tool requires `app_id`; FCP recognizes cross-app calls (`args.app_id != state.app_id`), gates on `workspace:<target_ws>/msg.send`, dispatches to the target FeishuAppAdapter
- mock_feishu gains per-app namespacing + chat-membership rejection so it can simulate "app-B not member of chat-A"
- 3 structured failure modes on cross-app: `unknown_chat_in_app`, `forbidden`, `unknown_app`
- Cross-app strips `reply_to_message_id` + `edit_message_id` (source-app-scoped)

Spec: `docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md`

## Test plan

- [x] Unit: `mix test` (registry 3-tuple, FAA propagation, FCP cross-app dispatch + auth, CCProcess `<channel>` tag)
- [x] Unit (Python): cc_mcp reply schema; mock_feishu envelope shape, multi-app namespacing, membership rejection
- [x] E2E: `make e2e` — all four scenarios green sequentially

## Deferred

See `docs/notes/futures/multi-app-deferred.md`:
- ETS-wipe race window (low-impact, boot-only)
- Cross-tenant principal aliasing (out-of-scope — PR-C territory)
- Live Feishu smoke gate (separate cadence)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review (writing-plans skill §Self-Review)

**1. Spec coverage:**

| Spec section | Plan coverage |
|---|---|
| §2.1 Registry key extension | T1 |
| §2.2 `app_id` propagation | T1 (envelope) + T2 (`<channel>`) |
| §2.3 `<channel>` tag carries app_id | T2 |
| §2.4 Reply tool schema | T3 |
| §2.5 FCP cross-app dispatch + auth | T4 |
| §2.7 Workspace resolution + naming contract | T4 (uses existing `workspace_for_chat/2`) |
| §2.8 Hook seam | T4 (call sites left explicit, no impl per spec) |
| §5.1 Setup | T8 (helpers) + T9 (script) |
| §5.2 / 5.2b Steps 1 + 1b | T9 |
| §5.3 Step 2 cross-app forward | T9 |
| §5.4 / 5.5 Steps 3 + 4 (forbidden / non-member) | T4 (unit) — E2E deferred per T9 note |
| §5.6 Step 5 cleanup | T9 |
| §6.1 Mock envelope completeness | T5 |
| §6.2 Per-app namespacing | T6 |
| §6.3 Mock chat-member rejection | T7 |
| §7 Backwards compat | T1 (FAA fallback), T6 (default bucket), T10 (prompt updates) |
| §8 Test pyramid | T1, T2, T3, T4, T5, T6, T7 each ship contract/unit BEFORE §9 E2E |
| §9 Risks documented | §11 task creates `futures/multi-app-deferred.md` |

Gap noted: §5.4 / §5.5 E2E coverage deferred to a follow-up. T4 unit-tests the structured errors comprehensively, which mitigates the gap; the E2E adds prompt-conditioning fragility we can revisit if needed.

**2. Placeholder scan:** No "TBD"/"TODO"/"implement later" found. Each step has executable code or a concrete command. The §5.4/§5.5 deferral is explicit, not a placeholder.

**3. Type consistency:**

- `lookup_by_chat_thread(chat_id, app_id, thread_id)` — same shape across T1 production code, T1 test, T4 test setup
- `register_session(session_id, %{chat_id, app_id, thread_id}, refs)` — consistent
- `args["app_id"]` — same key across Python adapter (T1), FAA (T1), FCP (T2), `<channel>` tag (T2)
- mock_feishu `register_chat_membership(app_id, chat_id)` — consistent across T6 (introduction), T7 (use), T8 (helper)
- `MOCK_FEISHU_PORT_DEV` / `MOCK_FEISHU_PORT_KANBAN` — consistent across T8 + T9

No drift.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-04-25-pr-a-multi-app.md`.

Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review between tasks (spec-compliance + code-quality), fast iteration. Best for plans with this many cross-cutting test files where context-isolation per task helps.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Best when implementation needs heavy interactive debugging (e.g., the scenario 04 step that may need 1-3 iterations).

Which approach?
