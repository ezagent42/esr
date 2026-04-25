# PR-A Multi-App E2E Design (v1.1)

Author: brainstorming session with user (linyilun), 2026-04-25
Date: 2026-04-25
Status: v1.1 — incorporates code-review findings (5 must-fix + 5 nice-to-have)

### Changelog
- **v1.1 (2026-04-25)** — code-review pass. Must-fix: (1) §2.7 added — explicit workspace resolution mapping `(chat_id, app_id) → workspace_name` via existing `Esr.Workspaces.Registry`; (2) §2.5 cross-app dispatch now strips `reply_to_message_id` + `edit_message_id` since those are scoped to the source app's message space; (3) §10 T1+T2 task ordering fixed — merged into single atomic T1 so registry shape change + envelope `app_id` propagation land together; (4) §5.2 added concurrent-isolation step (true seed-1, not just sequential); (5) §9 added risk on principal-identity across apps. Nice-to-have: §10 T2 split ergonomics, §8 added cross-app dispatch integration test, §3 promoted naming contract from risk to §2.7, §5.4 assertion uses structural marker not free-form text. §11 open questions reduced to one (workspace ↔ app coupling).
- **v1.0 (2026-04-25)** — initial draft from brainstorm.
Branch: TBD (will be `feature/pr-a-multi-app` off `origin/main` after the mock-fidelity audit branch lands)

Relates to:
- `docs/notes/mock-feishu-fidelity.md` — pre-condition audit; sign-off checklist in §9 of that doc gates this PR's testability
- `docs/notes/e2e-pyramid-lessons.md` — testing-pyramid principles this PR consciously follows (walking-skeleton first, contract tests at boundaries)
- `docs/notes/cc-mcp-pubsub-race.md` — patterns we're reusing for the cross-app dispatch path
- `docs/guides/writing-an-agent-topology.md` §三 — full feishu→cc message flow this PR extends

---

## 1. Overview

### 1.1 Goal

Add E2E coverage for **multi-app coexistence + cross-app forwarding**
on top of the now-passing single-app scenarios 01/02/03. Concretely:

1. ESR can host two `feishu_app_adapter_<instance>` admin actors side
   by side without traffic crossover. Each app's inbounds reach only
   its own session(s); each app's outbounds source from the right bot
   identity.
2. A CC session originating from app-A can call its `reply` tool with
   an explicit `target_app_id` to send a message to a chat in app-B.
   Authorization gates the cross-app path. Failure path is observable.
3. An E2E scenario (scenario 04) exercises (1) and (2) end-to-end
   against an upgraded mock_feishu that simulates multi-app routing
   correctly.

### 1.2 Non-goals

- **Group chat with multiple bots** (originally seed 3 / "PR-B"). The
  registry key extension here will support it, but `at_users` parsing,
  group access policy, and group-mention disambiguation are deferred
  to PR-B. PR-A single-app+p2p chats only.
- **CC creates an app via CLI** (originally seed 4 / "PR-C"). Lives on
  its own track — workspace skill that wraps `esr admin submit
  register_adapter`. Not coupled to PR-A.
- **Same `chat_id` reaching ESR via two `app_id`s simultaneously**
  (group chat where two bots are co-members). The 3-tuple registry
  key supports this layout — different `(chat_id, app_id)` rows for
  the same chat — but PR-B asserts the inbound disambiguation
  semantics. PR-A only proves the registry-key shape works; concurrent
  inbound to the same `chat_id` from two apps is PR-B scope.
- **Live Feishu testing.** Mock-only, same as scenarios 01/02/03. The
  fidelity audit (`docs/notes/mock-feishu-fidelity.md`) §4 calls out
  that mock-pass ≠ prod-pass for cross-app authorization specifically.
  A "live smoke gate" is tracked as backlog, not blocking PR-A merge.
- **Prompt-driven vs yaml-topology routing.** Recorded as a
  post-scenario-pass discussion item (task #128).
- **New agent type.** All work happens within the existing `cc` agent.
  See §3 for why no yaml change is needed.

### 1.3 Why this scope

User's compositional insight (2026-04-25 brainstorm): if the
SessionRegistry key extends from `(chat_id, thread_id)` to `(chat_id,
app_id, thread_id)`, multi-app coexistence falls out for free —
`(chat_a, app_a)` and `(chat_b, app_b)` are distinct keys, distinct
sessions, no crossover. The remaining work is a CC tool extension to
let claude *target* a different app.

Two atomic, complementary changes — one PR.

---

## 2. Architecture changes

### 2.1 SessionRegistry key extension

**Before** (`runtime/lib/esr/session_registry.ex:38-51`):

```elixir
@ets_table :esr_session_chat_index
# ETS row: {{chat_id, thread_id}, session_id, refs}

def lookup_by_chat_thread(chat_id, thread_id) do
  case :ets.lookup(@ets_table, {chat_id, thread_id}) do
    [{_k, sid, refs}] -> {:ok, sid, refs}
    [] -> :not_found
  end
end
```

**After**:

```elixir
# ETS row: {{chat_id, app_id, thread_id}, session_id, refs}

def lookup_by_chat_thread(chat_id, app_id, thread_id) do
  case :ets.lookup(@ets_table, {chat_id, app_id, thread_id}) do
    [{_k, sid, refs}] -> {:ok, sid, refs}
    [] -> :not_found
  end
end
```

The 3-arity replaces the 2-arity at every call site. There is no
backwards-compat 2-arity wrapper because keys would silently miss for
existing rows that didn't have app_id (a write-after-upgrade hazard).
A migration step in PR-A wipes the ETS table on first boot — safe
because the table is in-memory only and rebuilt from `register_session`
calls.

### 2.2 `app_id` propagation through inbound envelope

`adapters/feishu/src/esr_feishu/adapter.py:_emit_events_mock` (and
`_emit_events_lark`) yields:

```python
yield self._build_msg_received_envelope(
    args={
        "chat_id": chat_id,
        "app_id": self.app_id,   # ← NEW (was implicit via channel topic)
        "message_id": ...,
        ...
    },
    sender_open_id=sender_open_id,
)
```

Then `runtime/lib/esr/peers/feishu_app_adapter.ex:handle_upstream/2`
reads `args["app_id"]` (or falls back to `state.instance_id` for
backwards compat with older adapter versions) and threads it into:

- `SessionRegistry.lookup_by_chat_thread(chat_id, app_id, thread_id)`
- `Phoenix.PubSub.broadcast("session_router", {:new_chat_thread, app_id, chat_id, thread_id, env})` (matches existing 5-tuple)

The `:new_chat_thread` PubSub broadcast already carries `app_id` as
its second slot — `runtime/lib/esr/session_router.ex:187`. Today it's
unused for routing; PR-A wires it into `register_session/3`.

### 2.3 `<channel>` tag carries `app_id`

`runtime/lib/esr/peers/cc_process.ex:build_channel_notification/2`
already builds the envelope cc_mcp ships into claude as a `<channel>`
tag. Add `"app_id"` field, sourced from the upstream meta:

```elixir
%{
  "kind" => "notification",
  "source" => Map.get(ctx, "channel_adapter") || "feishu",
  "chat_id" => Map.get(last, :chat_id) || ...,
  "app_id" => Map.get(last, :app_id) || ...,    # ← NEW
  "thread_id" => ...,
  "message_id" => ...,
  "user" => ...,
  "ts" => ...,
  "content" => text
}
```

`feishu_chat_proxy.ex:handle_upstream({:feishu_inbound, env}, state)`
extracts `app_id` from envelope args and stuffs it into the meta map
sent downstream — already does this for `chat_id`, `thread_id`,
`message_id`, `sender_id`. One field added (~3 lines).

Result: claude sees `<channel app_id="cli_a..." chat_id="oc_..."
user="..." ...>...</channel>` for every inbound. CC knows which app
the message came from.

### 2.4 Extended `reply` tool — `app_id` parameter

`adapters/cc_mcp/src/esr_cc_mcp/tools.py:_REPLY` schema gets one
required field:

```python
_REPLY = Tool(
    name="reply",
    inputSchema={
        "type": "object",
        "properties": {
            "chat_id": {"type": "string"},
            "app_id": {"type": "string",         # ← NEW, REQUIRED
                       "description": "App ID (cli_xxx or ESR instance_id) — must be specified explicitly to avoid accidental cross-app posts. Take this from the inbound <channel> tag's app_id, or from a `forward` request's target app."},
            "text": {"type": "string"},
            "edit_message_id": {"type": "string"},
            "reply_to_message_id": {"type": "string"},
        },
        "required": ["chat_id", "app_id", "text"],   # ← app_id added
    },
)
```

**Per user direction**: `app_id` is REQUIRED on every call, no default.
Forces CC to think about target every time and avoids accidental
cross-app posts. The schema description tells claude where to source
it.

### 2.5 FCP cross-app dispatch + authorization

`runtime/lib/esr/peers/feishu_chat_proxy.ex:dispatch_tool_invoke("reply", args, ...)`:

```
chat_id   = args["chat_id"]
app_id    = args["app_id"]
text      = args["text"]

if app_id == state.app_id:
  # Home-app path — unchanged behaviour. reply_to_message_id +
  # edit_message_id stay valid because the message_id space is the
  # source app's.
  forward_reply(text, reply_to_message_id, state)
else:
  # Cross-app path. reply_to_message_id and edit_message_id refer to
  # the SOURCE app's message_id space; the target app has no notion
  # of those ids and would reject. Strip them at FCP rather than
  # bouncing through the round-trip — and surface a debug log so
  # CC's prompt design can be tightened if it keeps mistakenly
  # passing them.
  if reply_to_message_id != "" or edit_message_id != "":
    Logger.info("FCP cross-app: stripping reply_to/edit ids " <>
                "(target_app=#{app_id}, source_app=#{state.app_id})")

  target_ws = Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id)  # see §2.7

  case Capabilities.has?(state.principal_id,
                         "workspace:#{target_ws}/msg.send"):
    :ok ->
      # Find the target FeishuAppAdapter by app_id
      case lookup_target_app_proxy(app_id):
        {:ok, target_pid} ->
          send(target_pid, {:outbound, %{
            "kind" => "reply",
            "args" => %{"chat_id" => chat_id, "text" => text}
          }})
          reply_tool_result(channel_pid, req_id, true,
                            %{"dispatched" => true, "cross_app" => true})
        :not_found ->
          reply_tool_result(channel_pid, req_id, false, nil,
            %{"type" => "unknown_app", "app_id" => app_id,
              "message" => "no FeishuAppAdapter for app_id=..."})
    {:missing, _} ->
      reply_tool_result(channel_pid, req_id, false, nil,
        %{"type" => "forbidden", "app_id" => app_id, "chat_id" => chat_id,
          "workspace" => target_ws,
          "message" => "principal lacks msg.send for target workspace"})
```

Three failure modes, all with structured tool_result errors:
- `unknown_app` — no adapter for that app_id (typo / not registered)
- `forbidden` — principal not authorized for target workspace
- (downstream) `directive_ack ok:false` — target adapter rejected (mock simulates real Feishu's "app-B not member of chat-A" rejection); surfaces as a delayed second tool_result

**Authorization rule** (per Q2 in brainstorm): only check target
workspace's `msg.send`. Principal must be authorized to send to where
they're sending — symmetric with inbound's Lane A.

### 2.7 Workspace resolution + `app_id` naming contract

**Workspace resolution.** Cross-app authorization needs to map
`(chat_id, app_id) → workspace_name`. The mapping already exists at
`runtime/lib/esr/workspaces/registry.ex:workspace_for_chat/2` —
session_router uses it for inbound's `enrich_params`
(`session_router.ex:352`). PR-A reuses the same function for
outbound. No new module, no new yaml.

If `workspace_for_chat(chat_id, app_id)` returns `:not_found`, FCP
short-circuits with `tool_result ok:false, error.type:
"unknown_chat_in_app"`. This is the "user typed wrong chat_id /
not registered in workspaces.yaml" failure mode.

**`app_id` naming contract** (locked here for PR-A, reaffirmed
across PR-C):

- Every place CC sees `app_id` (in `<channel>` tag, in `reply` tool,
  in error payloads) the value is an **ESR `instance_id`** — the
  string in `adapters.yaml` `instances:` keys, e.g.
  `feishu_app_e2e-mock`, `feishu_dev`, `feishu_kanban`.
- The real Feishu `cli_xxx` app_id stays internal to the FAA / Python
  adapter — it's used only for talking to the Feishu API.
- Mapping `instance_id ↔ cli_xxx` lives in `adapters.yaml` per-
  instance config (today already the case via `app_id: cli_...` in
  the config map).
- PR-C, when it adds "CC creates a new app", registers the new
  adapter with both its ESR instance_id (CC choses it) and its
  Feishu cli_xxx (returned by the create-app wizard). CC continues
  to refer to the new app by instance_id only.

This contract means CC's mental model is "ESR routing identifier" —
never has to know Feishu's wire identity. Reduces drift surface.

### 2.8 Hook seam (deferred implementation)

`forward_reply` cross-app branch leaves a hook seam:

```elixir
# T-comms-3p (future): per-target-app content filter chain
case ContentFilter.run(target_app_id, text) do
  {:ok, filtered_text} -> emit(target_app_id, filtered_text)
  {:reject, reason} -> reply_tool_result(..., :filter_rejected, reason)
end
```

PR-A doesn't implement filters — just leaves the call site explicit
so PR-D can plug in (e.g., "no passwords to cli_xx app").

---

## 3. Wire contracts

### 3.1 Inbound envelope (`adapter:feishu/<instance>` channel)

```json
{
  "id": "e-...",
  "kind": "event",
  "payload": {
    "args": {
      "chat_id":   "oc_...",
      "app_id":    "cli_...",        // ← NEW (required for routing)
      "thread_id": "",
      "message_id": "om_...",
      "content":   "...",
      "sender_id": "ou_...",
      "sender_type": "user",
      "msg_type": "text",
      "raw_content": "..."
    },
    "event_type": "msg_received"
  },
  "principal_id": "ou_...",
  "workspace_name": "ws-name",
  "source": "esr://localhost/adapter:feishu/<instance>",
  "ts": "2026-04-25T...",
  "type": "event"
}
```

### 3.2 `<channel>` tag visible to claude

```xml
<channel
  source="feishu"
  chat_id="oc_..."
  app_id="cli_..."         <!-- NEW -->
  thread_id=""
  message_id="om_..."
  user="ou_..."
  ts="2026-04-25T..."
>{user's text}</channel>
```

### 3.3 `reply` MCP tool

```json
{
  "name": "reply",
  "input": {
    "chat_id":              "oc_...",   // required
    "app_id":               "cli_...",  // required (NEW — explicit, no default)
    "text":                 "...",      // required
    "edit_message_id":      "...",      // optional
    "reply_to_message_id":  "..."       // optional
  }
}
```

### 3.4 `tool_invoke` envelope on `cli:channel/<sid>`

`args.app_id` flows verbatim from `reply` → tool_invoke → FCP. No
re-shape between cc_mcp and ESR.

---

## 4. Design decisions log (from brainstorm)

| # | Question | Decision | Rationale |
|---|---|---|---|
| Q1 | How does CC know which app_id to use? | In-band `<channel>` tag has `app_id` field; CC echoes it in `reply` | No discovery tool needed for home-app reply; cross-app target chosen by prompt |
| Q2 | Authorization: source ws, target ws, both? | Target only | Symmetric with inbound (each msg gated by receiver's workspace cap) |
| Q3 | Failure observability | CC handles via reply to home chat | Most flexible; mock doesn't enforce specific UX |
| Q4 | Topology: extend `cc` agent or new agent? | Extend `cc`, no new yaml entry | Pipeline shape unchanged; only registry key + tool schema evolve |
| — | Cross-app via new `forward` tool or extended `reply`? | Extended `reply` (option b in brainstorm) | Fewer tools = less likely to misroute; explicit `app_id` keeps decision clear |
| — | Default for `app_id` parameter | Required, no default | Prevents accidental cross-app post |
| — | Hook for content filtering | Seam reserved, not implemented | Future PR-D scope |

---

## 5. Scenario 04 storyboard

### 5.1 Setup (in `tests/e2e/scenarios/04_multi_app_routing.sh`)

```bash
seed_two_apps_workspaces        # ws_dev → app_dev, ws_kanban → app_kanban
seed_two_adapters               # feishu_app_dev, feishu_app_kanban
start_two_mock_feishus          # ports 8201 + 8202
start_esrd
wait_for_two_sidecars_ready 30  # both feishu_adapter_runner sidecars connected
```

### 5.2 Step 1 — single-app inbound, no crossover (seed 1, sequential)

Push inbound to app_dev's chat with content "Please reply with: ack-dev-only".

Assert:
- mock_feishu_dev.sent_messages includes "ack-dev-only" (matches scenario 01)
- mock_feishu_kanban.sent_messages is empty
- One `thread:<sid>` actor exists, registry key `(chat_id_dev, app_dev, "")`

### 5.2b Step 1b — concurrent isolation under load (seed 1, concurrent)

Push inbounds **interleaved** (not sequential — both fired with `&`
backgrounded) to:
- app_dev's chat: "Reply with: ack-dev-iso"
- app_kanban's chat: "Reply with: ack-kanban-iso"

Assert:
- Two distinct `thread:<sid>` actors exist (different session_ids)
- mock_feishu_dev.sent_messages includes "ack-dev-iso" but NOT
  "ack-kanban-iso"
- mock_feishu_kanban.sent_messages includes "ack-kanban-iso" but
  NOT "ack-dev-iso"
- esrd log shows two distinct `session_router: auto-created` lines
  with different session_ids

This catches the failure mode where multi-app routing is
implemented sequentially (one global mutex) — race conditions
where one CC's response leaks into the other's reply path. Drives
the 3-tuple registry key correctness under load.

### 5.3 Step 2 — cross-app forward (seed 2b)

Push inbound to app_dev's chat with content:

> "Please do two things: (1) reply 'ack-dev' to me; (2) forward this summary to app_kanban chat oc_kanban_X: 'progress: dev finished step 1'"

Assert:
- mock_feishu_dev.sent_messages includes "ack-dev"
- mock_feishu_kanban.sent_messages includes "progress: dev finished step 1"
- The kanban send was sourced from app_kanban's bot (`sender.sender_id.open_id = bot_kanban_open_id`), not app_dev's
- esrd log shows `dispatched cross_app: true` from FCP

### 5.4 Step 3 — forbidden cross-app (negative path)

Configure: ou_admin has cap `workspace:ws_dev/msg.send` but NOT
`workspace:ws_kanban/msg.send`.

Push inbound to app_dev: "Forward 'unauthorized' to app_kanban chat
oc_kanban_X."

Assert:
- mock_feishu_kanban.sent_messages does NOT include "unauthorized"
- esrd log shows tool_result `ok: false, error.type: "forbidden"`
- mock_feishu_dev.sent_messages includes a structural marker the
  prompt instructs CC to emit on failure (e.g.
  `"[forward-failed: forbidden]"`). Asserting on the marker, not on
  free-form CC explanation text, keeps the test deterministic.

### 5.5 Step 4 — non-member chat (mock simulates real-Feishu rejection)

Configure: app_kanban is NOT a member of `oc_orphan_chat`.

Push inbound to app_dev: "Forward to app_kanban chat oc_orphan_chat:
'test'."

Assert:
- mock_feishu_kanban rejects the outbound `POST /im/v1/messages` with
  `code != 0`
- esrd log shows tool_result `ok: false, error.type:
  "directive_failed"` (or similar — exact shape during impl)
- CC's home reply explains the failure to user

### 5.6 Step 5 — cleanup

End both sessions via `esr admin submit session_end --arg
session_id=...`. Assert no `thread:` actors remain.

---

## 6. Mock fidelity remediation (PR-A scope)

Pulled from `docs/notes/mock-feishu-fidelity.md` §8 — only the rows
that block PR-A. Other rows defer to PR-B and beyond.

### 6.1 Inbound envelope completeness (~30 min)

Add to `mock_feishu.py:push_inbound`:
- `header.tenant_key`
- `event.sender.sender_id.user_id` (short ID — synthetic ok in mock)
- `event.sender.sender_id.union_id`
- `event.sender.tenant_key`
- `event.message.update_time`
- `event.message.user_agent`
- (optional: `root_id`, `parent_id` for thread support)

Backwards-compat: existing FCP/FAA code ignores extras, so adding
fields is safe. The Python adapter (`_emit_events_mock`) already
unpacks generously.

### 6.2 Per-app namespacing (~2 h)

`MockFeishu` data model evolves from global lists to per-app maps:

```python
self._ws_clients: dict[str, list[WebSocketResponse]] = {}    # app_id → clients
self._sent_messages: dict[str, list[dict]] = {}              # app_id → records
self._reactions: dict[str, list[dict]] = {}                  # app_id → records
self._un_reactions: dict[str, list[dict]] = {}
self._chat_membership: dict[str, set[str]] = {}              # app_id → {chat_id}
```

API changes:
- `push_inbound(chat_id, sender_open_id, app_id, ...)` — `app_id` required;
  routes only to that app's WS clients
- `POST /open-apis/im/v1/messages` — needs to identify caller's app.
  Options: (a) Authorization header, (b) URL prefix per app
  (`/app/<id>/open-apis/...`), (c) a request-time `X-App-Id` header.
  Recommendation: (c) — simplest, doesn't break existing scenarios
  if `X-App-Id` defaults to "default"
- Membership check on outbound: reject if `chat_id not in
  self._chat_membership[app_id]`. Membership pre-seeded at test start
  via a new `register_chat_membership(app_id, chat_id)` API.
- `GET /sent_messages?app_id=...` — query parameter to scope listings;
  default returns all (existing scenario-01/02/03 don't pass `app_id`,
  get the union; works because they only use one app)

### 6.3 Sign-off (matches `docs/notes/mock-feishu-fidelity.md` §9)

PR-A merge gated on:

- [ ] Mock inbound envelope matches `live-capture/text_message.json`
  field-for-field
- [ ] Per-app namespacing in mock_feishu.py
- [ ] Cross-app outbound rejected when app isn't chat member
- [ ] Scenarios 01-03 still pass against the upgraded mock
- [ ] mock-fidelity audit doc updated to reflect what landed

---

## 7. Backwards compatibility

Existing scenarios 01/02/03 today pass `app_id` only via implicit
adapter `instance_id` (= `feishu_app_e2e-mock`). Post-PR-A:

- Their inbound envelopes will gain `app_id` field — silently ignored
  by their assertions (no assert_*_lacks `app_id`)
- Their `reply` tool calls today don't include `app_id` — schema
  change makes it required → THEIR PROMPT MUST BE UPDATED to instruct
  CC to include the home `app_id`. Three lines of test prompt edit.
- Their auto-create path goes through the new 3-arity registry call;
  `app_id` defaults to the inbound envelope's value (which we also
  add). No assertions break.

`agents.yaml` `cc` agent — no change (yaml schema is shared).

---

## 8. Test pyramid alignment

Per `docs/notes/e2e-pyramid-lessons.md`, each new mechanism gets a
regression test at its own layer BEFORE the E2E:

| Mechanism | Unit test | Integration | E2E |
|---|---|---|---|
| Registry 3-arity key | `session_registry_test.exs` (already exists; extend) | — | scenario 04 step 1 |
| `<channel>` tag carries app_id | `cc_process_test.exs` (extend `build_channel_notification` test) | — | scenario 04 step 2 |
| reply tool app_id required | `cc_mcp` python test (new) | — | scenario 04 step 2 |
| FCP cross-app dispatch | `feishu_chat_proxy_test.exs` (new test) | — | scenario 04 step 2 |
| FCP cross-app authorization | `feishu_chat_proxy_test.exs` (new test) | — | scenario 04 step 3 |
| Mock per-app namespacing | `py/tests/scripts/test_mock_feishu_multi_app.py` (new) | — | scenario 04 step 1 |
| Mock chat-member rejection | same | — | scenario 04 step 4 |

Total new tests: ~6. The retrospective said next round should land
8/8 for E2E-surfaced bugs; here we land contract+unit BEFORE the E2E
runs, which is the goal pattern.

---

## 9. Risks (known unknowns)

1. **Mock vs real Feishu cross-app**: mock simulates app-membership
   rejection at our discretion (test-controlled), but real Feishu's
   exact error code + retry semantics are not characterized. Live
   smoke gate is tracked as backlog (deferred from this PR).
2. **Session migration**: ETS table wipe on first boot post-upgrade
   means any in-flight sessions get re-registered as new keys. Should
   be invisible to users (sessions reach steady state again on first
   inbound), but worth a single line in deploy notes.
3. **`app_id` semantic drift**: in the topology yaml `${app_id}` is
   the ESR `instance_id`; in mock_feishu / Feishu API it's `cli_xxx`.
   PR-A must consistently use ESR `instance_id` everywhere claude
   sees `app_id` (so CC's `reply(app_id=...)` accepts an ESR identifier).
   Mapping `cli_xxx ↔ instance_id` lives in adapters.yaml — already
   the case.
4. **Tool schema breaking change**: `app_id` required in `reply` is a
   wire-incompatible change. Any external CC sessions running the old
   schema would error on missing field. Acceptable because cc_mcp ships
   with esrd as one unit; no third-party callers.
5. **Principal identity across apps**: the authorization gate in §2.5
   reads `Capabilities.has?(state.principal_id, "workspace:<target>/msg.send")`.
   `state.principal_id` was set when the session was authenticated for
   the SOURCE app's inbound (Lane A). PR-A assumes the same
   `principal_id` (the human's `ou_xxx`) is also pre-registered in the
   target workspace's `capabilities.yaml`. **Cross-app PRINCIPAL
   identity is not auto-linked**: a Feishu user has a different
   `open_id` per tenant, so two apps under different tenants would see
   the same human as two separate principals. This means the same
   user accessing both `app_dev` and `app_kanban` (which is Feishu's
   normal model when both apps are under the same tenant) is fine —
   but cross-tenant cross-app would break. Test scenarios use one
   tenant; PR-C / future cross-tenant work would need a separate
   `principal_alias` table. Out of scope for PR-A.
6. **ETS wipe race window**: §2.1 wipes the registry table on first
   boot post-upgrade. If an inbound arrives during the ~ms between
   table-clear and the first re-register, `lookup_by_chat_thread`
   returns `:not_found` and triggers auto-create — duplicate sessions
   for that mid-flight inbound. Boot is normally quiescent so impact
   is low; tracked as a deferred-fix in `docs/notes/futures/`.

---

## 10. Task decomposition (for writing-plans)

T1 was originally split from T2, but the spec review caught that
T1 alone breaks scenario 01 — the registry's 3-arity callers
include FeishuAppAdapter, which needs `args["app_id"]` from the
inbound. Merging the registry shape change with the inbound
propagation lands them as one atomic correctness boundary.

Atomic tasks (one commit per task ideally):

1. **T1** *(was T1+T2-envelope merged)*: SessionRegistry key extension
   to 3-tuple `(chat_id, app_id, thread_id)` AND `app_id` propagation
   through inbound — Python adapter adds `args["app_id"]`,
   FeishuAppAdapter reads it (with fallback to `state.instance_id`
   for safety), 3-arity registry call, ETS table wipe on first boot
   so any pre-upgrade rows don't ghost-collide.
2. **T2** *(was T2-CCProcess split out)*: `<channel>` tag carries
   `app_id` — CCProcess `build_channel_notification/2` adds the
   field; FCP meta map already gains it from T1's envelope work.
   Pure presentation-surface change, separately reviewable from the
   wire change.
3. **T3**: cc_mcp `reply` tool schema adds required `app_id`; Python
   schema test asserting `app_id` is required.
4. **T4**: FCP `dispatch_tool_invoke("reply")` cross-app branch with
   authorization gate (`workspace_for_chat` lookup + caps check) +
   integration test that spawns two FAAs, fires an outbound at FCP
   with foreign app_id, asserts it lands in the correct FAA
   mailbox.
5. **T5**: mock_feishu inbound envelope completeness (audit §6.1
   fields).
6. **T6**: mock_feishu per-app namespacing — data model + endpoint
   changes; new test file `test_mock_feishu_multi_app.py`
   (namespacing only).
7. **T7**: mock_feishu chat-membership rejection on outbound; new
   test file `test_mock_feishu_membership.py` (separate from T6 so
   the policy concern isn't tangled with the data-model concern).
8. **T8**: scenario 04 script + common.sh helpers (`seed_two_apps`,
   `start_two_mock_feishus`, `wait_for_two_sidecars_ready`).
9. **T9**: scenario 04 test prompts (with structural failure markers
   per §5.4) + assertions for steps 1, 1b (concurrent), 2, 3, 4, 5.
10. **T10**: existing scenarios 01-03 prompt edits to include
    `app_id` parameter explicitly. Depends on T3 (schema change).
11. **T11**: docs/notes/mock-feishu-fidelity.md sign-off update +
    docs/guides/writing-an-agent-topology.md cross-references for
    multi-app + `<channel>` tag `app_id`.

Dependency edges (refined post-review):

- T1 ← T2 (T2 reads `app_id` already plumbed by T1)
- T1 ← T4 (T4 needs the registry shape)
- T1 ← T3 (T3 tool schema needs the wire path proven first)
- T3 ← T10 (T10 must update prompts to match the now-required
  schema; otherwise scenarios 01-03 break post-T3)
- T5/T6/T7 ← T8 (scenario needs upgraded mock)
- T6 ← T7 (membership lives in per-app namespace)
- T8 ← T9
- T1-T10 ← T11

Critical path: T1 → T4 → T8 → T9 → T11. Roughly 2 days of work.

---

## 11. Open questions — all settled

All resolved in v1.1+:

- **Workspace ↔ app coupling**: keep multi-app per workspace
  (locked 2026-04-25 user decision). `workspaces.yaml` `chats: [{chat_id,
  app_id, ...}]` continues to accept heterogeneous apps in one
  workspace. Authorization gate at §2.5 looks up workspace per
  `(chat_id, app_id)` pair via `workspace_for_chat/2`, so the schema
  already supports this — no enforcement work needed.
- Mock caller identification: `X-App-Id` request header.
- Forward-failure observability: CC handles via reply with structural
  marker; FCP does not auto-emit fallback.
- `app_id` naming contract: ESR `instance_id`, never `cli_xxx` (§2.7).
