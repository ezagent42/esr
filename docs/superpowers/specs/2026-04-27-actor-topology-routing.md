# Actor topology routing — design spec

**Date**: 2026-04-27
**Status**: design (post-grill, pre-implementation)
**Author**: dev (linyilun) — captured via `/grill-me` discussion 2026-04-26 → 2026-04-27
**Builds on**: PR-A multi-app E2E (#53), Lane A drop (#54)
**Targets**: PR-B (URI migration), PR-C (topology + reachable_set)

---

## 1. Why now

PR-A made cross-app reply work via the `<channel>` tag carrying `app_id`
and FCP's `dispatch_cross_app_reply`. CC currently learns about other
chats *only by looking at the inbound `<channel>` tag of the message
it's responding to* — there is no mechanism for CC to know that
`oc_kanban_room` exists unless someone in `oc_kanban_room` sends it
something first.

That works for the "reply within the conversation that just arrived"
case but not for the natural cross-team workflow:

> User in `ws_dev`: "@bot please post 'sprint status: blocked on review'
> to the kanban room"

CC doesn't know `oc_kanban_room`'s URI, so it can't construct a
`reply(chat_id=...)` call. It either refuses, hallucinates a chat_id,
or asks the user.

This spec defines a self-organising actor topology: yaml declares the
neighbour graph; sessions learn additional actors via runtime
observation (BGP-style propagation); CC sees its current reachable
set in the `<channel>` tag and can address any of them with the
existing `reply` / `react` / `send_file` tools.

## 2. The actor-uniform model

The single most important framing: **agent / chat / user are all
"actors"** — addressable nodes in a topology. The system doesn't
distinguish "agent-to-agent query" from "chat-to-chat forward" at
the address layer; both reduce to "send a message to actor X".
Whether the caller waits for a reply (RPC-shaped) or fires-and-forgets
is a property of the messaging primitive, not the addressee.

ESR maps this onto its existing process tree:

- **Active actor** = peer with a GenServer + state. Today: CC peer.
  Tomorrow: voice agent, planner agent, etc. Each owns its own
  `reachable_set`.
- **Passive actor** = address only, no per-instance process. Today:
  chat (resolved to its session's FCP at delivery time), user
  (resolved to their DM session or @-mention context), adapter
  (FAA peer, but addressed as infrastructure not as a peer).

Sessions are *containers*, not actors. They aggregate peers but
themselves are not directly addressable for messaging.

## 3. URI scheme — path-style RESTful

### 3.1 Shape

```
esr://<instance>/workspaces/<ws>/chats/<chat_id>      # chat actor
esr://<instance>/users/<open_id>                       # user actor
esr://<instance>/adapters/<platform>/<app_id>          # platform adapter
esr://<instance>/sessions/<session_id>                 # session container (informational)
esr://<instance>/sessions/<sid>/peers/<kind>/<id>      # peer direct (future)
```

Rules:

- Path segments only, no `<type>:<id>` colon-style mixing.
- Each URI uniquely identifies one actor; no compound query-string
  forms.
- Workspace nesting applies to chats (since chats live in workspaces).
  Users and adapters don't nest under workspace (open_id is
  tenant-global; adapter app_id is tenant-global).

### 3.2 Migration from current scheme

Current ESR uses two co-existing forms:

- `esr://localhost/adapter:<platform>/<app_id>` — emitted by **Python**
  at `py/src/_adapter_common/runner_core.py:163,255` (`source_uri =
  "esr://localhost/" + topic` where `topic = f"adapter:{name}/{id}"`).
  *Parsed* by Elixir at `runtime/lib/esr/peer_server.ex:894`
  (`@feishu_source_re ~r{^esr://[^/]+/adapter:feishu/([^/]+)$}`).
- `esr://localhost/admin/<peer_id>` — emitted by **Elixir** at
  `runtime/lib/esr/peers/feishu_app_adapter.ex:212,221` for the FAA
  peer's self-source.
- `esr://localhost/actor/<actor_id>` — emitted at
  `runtime/lib/esr/peer_server.ex:676,846` for non-feishu actors.
- `esr://localhost/runtime` — emitted at
  `runtime/lib/esr/handler_router.ex:43`.

Both `Esr.Uri` (`runtime/lib/esr/uri.ex:1-114`) and its Python mirror
`esr.uri` (`py/src/esr/uri.py:1-144`) **already exist** but only
accept 2-segment paths `<type>/<id>` with
`@valid_types ~w(actor adapter handler command interface)a`
(`uri.ex:18`). PR-B *extends* both modules — it does not introduce
them.

#### Disambiguating URI shape vs. PubSub topic shape

Several places use the literal string `"adapter:<name>/<id>"` as a
**Phoenix.PubSub topic** (independent of the URI):

- `peer_server.ex:662,872-874`
- `feishu_app_adapter.ex:159`
- `runner_core.py:255`
- Python `_adapter_common/main.py` and `cc_adapter_runner/_allowlist.py`
  subscribe by this topic.

**PR-B migrates URIs only**: the URI shape becomes path-style
RESTful (`esr://<inst>/adapters/<platform>/<id>`), while topic strings
keep their existing `"adapter:<name>/<id>"` form. The two are
decoupled; mixing the migrations would break the Python subscribe
contract for no design benefit.

#### Migration scope (Elixir)

| File | Change |
|---|---|
| `runtime/lib/esr/uri.ex` | Extend `@valid_types` to include `workspaces, chats, users, sessions, adapters`; allow 3+ segment paths for nested resources |
| `runtime/lib/esr/peer_server.ex:894` | `@feishu_source_re` → `~r{^esr://[^/]+/adapters/feishu/([^/]+)$}` |
| `runtime/lib/esr/peer_server.ex:676,846` | `actor/<id>` form review (non-feishu actors) — convert if migrating systematically, or note "out of scope, deferred" |
| `runtime/lib/esr/peers/feishu_app_adapter.ex:212,221` | `admin/<id>` self-source — separate decision: rename to `adapters/feishu/<id>` (canonical) or keep `admin/` as a system actor type |
| `runtime/lib/esr/handler_router.ex:43` | `esr://localhost/runtime` — keep (no `:` form, unaffected) |
| `runtime/test/esr/**` (55 grep hits) | Update asserted URI literals |

#### Migration scope (Python)

| File | Change |
|---|---|
| `py/src/esr/uri.py` | Mirror the Elixir extension (keep both sides in lockstep) |
| `py/src/_adapter_common/runner_core.py:163,255` | `source_uri` formation — keep `topic` (PubSub) string, change `source_uri` path-style |
| `py/src/esr/ipc/channel_pusher.py:28-30` | URI validation/build call sites |
| `py/src/esr/ipc/envelope.py:13,57-59` | Envelope wrap/unwrap |
| `adapters/feishu/src/esr_feishu/adapter.py` | Audit any direct URI string formation |

#### Migration scope (tests / scenarios / docs)

| File | Change |
|---|---|
| `tests/e2e/scenarios/04_multi_app_routing.sh` (and 01-03 if any greps URI literals) | grep / regex on logs |
| `docs/notes/manual-e2e-verification.md`, `docs/notes/lane-a-rca.md`, `docs/architecture.md` | Operator-facing URI strings |
| `adapters/feishu/tests/**` | **No URI literals today** (0 grep hits) — out of scope |

**All existing tests must still pass after migration with no
behavioural change.** This migration is its own PR (PR-B) so review
focus stays narrow.

## 4. Reachable set — BGP-style routing table

### 4.1 Concept

Each active actor maintains a `reachable_set: MapSet[URI]` representing
the actor URIs it currently knows about. Tag rendering exposes this
set; the LLM addresses `reply` / `react` / `send_file` calls by URI;
the runtime gate (Lane B from PR-A) decides whether the send is
authorised.

### 4.2 Initial seed

When a session starts, the CC peer's reachable_set is initialised from
the topology yaml. The seed includes:

- The session's own chat URI
- The adapter URI that delivered the inbound that bootstrapped the
  session
- Every URI in the workspace's declared `neighbors` list (see §6)

The yaml-declared neighbour expansion is symmetric (§6.4): if
`ws_dev` declares `workspace:ws_kanban` as a neighbour, `ws_kanban`'s
sessions also get `ws_dev`'s actors in their initial seed.

### 4.3 Discovery — BGP-style propagation

When an inbound envelope arrives at a CC peer, the runtime extracts URIs
from the envelope and merges any new ones into the reachable_set:

- **`source`**: the immediate sender's URI (e.g., the cc_process peer
  in the originating session, or the FAA adapter)
- **`principal_id`**: converted to `esr://<instance>/users/<open_id>`
  and added

URIs from `chat_id`+`app_id` (origin chat) are not added separately
because that's the session's own chat.

This matches the user's mental model:

> A's neighbours are {B}. B's neighbours are {A, C}. When B forwards
> a message originating from C to A, A's neighbour table grows to
> {B, C}. C learns A symmetrically when traffic flows the other way.

The propagation depends on the actual messaging behaviour of
intermediate actors. The runtime does NOT proactively flood routes.

### 4.4 Cap-failed URIs are still learned

If A learns C via propagation but A's principal lacks
`workspace:<C_ws>/msg.send`, the URI stays in A's reachable_set.
The cap gate at send time enforces; the reachable_set just records
"who I know exists." This separation matches the actor-uniform model
(all addressable actors are equal at the address layer).

### 4.5 Eviction

`reachable_set` only grows during a session's lifetime. It is reset
when the session ends. No TTL, no LRU, no explicit prune.

If a yaml-declared neighbour is removed during a hot-reload, the URI
stays in active sessions' reachable_sets (lazy removal — see §7).

## 5. State ownership — per actor, not per session

`reachable_set` lives on the **CC peer GenServer state**
(`runtime/lib/esr/peers/cc_process.ex`), not on SessionProcess.
Reasons:

- The reachable_set is the *agent's perspective on the world*. Two
  agents in the same session (a future possibility, e.g., a planner
  agent + a voice agent sharing a chat) might legitimately have
  different views.
- SessionProcess stays a pure lifecycle/supervision container.
- BGP learning lives on the same GenServer as the state it mutates →
  no cross-process sync.

### 5.1 Today's inbound envelope shape — and the gap

`cc_process.ex` does not receive a structured `envelope` map today.
By the time messages reach it, upstream peers (FCP at
`feishu_chat_proxy.ex`, then `cc_proxy.ex`) have unpacked the inbound
into `{:text, bytes, meta}` (`cc_process.ex:142,145`). The `meta` map
carries `chat_id, app_id, thread_id, message_id, sender_id`
(`cc_process.ex:380-407` `stash_upstream_meta` /  `event_to_map`) —
**but no `source` URI**.

Lane B's inbound cap gate lives upstream at `peer_server.ex:237-285`
(plus the `@feishu_source_re` parse at `peer_server.ex:894-945`), and
the outbound cross-app gate (`workspace:<ws>/msg.send`) lives at
`feishu_chat_proxy.ex:346-352`. Neither gate is in cc_process today.

So the spec's BGP-learning hook can't read `envelope.source` directly
in cc_process — that data isn't there yet. Two implementation paths:

**(a) Thread `source` URI through `meta` (recommended)**
- Modify `feishu_chat_proxy.ex` and `cc_proxy.ex` upstream to add
  `source: "esr://..."` and `principal_id: "ou_..."` to the meta map
  carried with `{:text, bytes, meta}`.
- `cc_process.ex` adds `handle_info` clauses that learn from `meta`
  before the existing handling.
- ~3 file changes upstream, but state stays on cc_process.

**(b) Move learning upstream**
- Put `reachable_set` learning in `peer_server.ex` or `feishu_chat_proxy.ex`
  (where `source` URIs are visible) and broadcast to cc_process for
  tag rendering.
- More entanglement; learning lives away from the actor that uses it.

PR-C uses **(a)**. The rest of this section assumes (a).

### 5.2 Code sketch

```elixir
# runtime/lib/esr/peers/cc_process.ex
defmodule Esr.Peers.CCProcess do
  defstruct ..., reachable_set: MapSet.new(), ...

  def init(args) do
    initial = Esr.Topology.initial_seed(args.workspace, args.chat_uri)
    {:ok, %__MODULE__{... | reachable_set: initial}}
  end

  # Existing clause shape (matches cc_process.ex:142,145):
  def handle_info({:text, bytes, meta}, state) do
    state = learn_uris(state, meta)        # ← new
    # existing tmux dispatch / channel-tag rendering follows
    {:noreply, state}
  end

  defp learn_uris(state, meta) do
    new =
      [meta[:source], principal_uri(meta[:principal_id])]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&MapSet.member?(state.reachable_set, &1))

    case new do
      [] -> state
      uris ->
        Logger.info("session #{state.session_id} learned: #{inspect(uris)}")
        %{state | reachable_set: MapSet.union(state.reachable_set, MapSet.new(uris))}
    end
  end

  defp principal_uri(nil), do: nil
  defp principal_uri(open_id), do: "esr://#{instance()}/users/#{open_id}"
end
```

The `meta[:source]` and `meta[:principal_id]` keys are added by PR-C
upstream (path (a) above).

## 6. Topology yaml

### 6.1 Location

Extend the existing `${ESRD_HOME}/<instance>/workspaces.yaml`. No new
yaml file.

⚠️ **fs_watch is NOT wired for `workspaces.yaml` today.**
`runtime/lib/esr/workspaces/registry.ex:68-80` (`load_from_file/1`)
loads once at boot; further updates come only from CLI calls
(`cli:workspace/register`).

PR-C must add a workspaces watcher modeled on
`runtime/lib/esr/capabilities/watcher.ex:21-22` (which uses
`FileSystem.start_link/subscribe` against
`${ESRD_HOME}/<instance>/capabilities.yaml`). Same pattern, new file.
This is task C6 (§9.2) and is non-trivial enough to call out separately.

### 6.2 Schema

```yaml
workspaces:
  ws_dev:
    chats:
      - chat_id: oc_dev_room
        app_id: feishu_app_dev
        kind: group
        name: dev-room                  # NEW: optional display name
      - chat_id: oc_dev_dm
        app_id: feishu_app_dev
        kind: p2p
        name: dev-dm
    neighbors:                          # NEW
      - workspace:ws_kanban
      - chat:oc_legal_special
      - user:ou_admin
      - adapter:feishu:app_other
```

### 6.3 Strict prefix

Every entry in `neighbors` uses the `<type>:<id>` form. No bare
strings, no implicit defaults — uniform parsing, no special cases.

Supported types in v1: `workspace`, `chat`, `user`, `adapter`.
Future: `agent`, `session`, etc. Adding new types is non-breaking.

### 6.4 Symmetry

Declaration is symmetric by default. If `ws_dev` declares
`workspace:ws_kanban` as a neighbour, `ws_kanban`'s sessions also
include `ws_dev`'s actors in their initial seed. This minimises yaml
maintenance — write the edge once, both endpoints benefit.

Asymmetric capabilities (e.g., `ws_dev` can post to `ws_kanban` but
not vice versa) are expressed via `capabilities.yaml`, not via the
neighbour graph. The cap system already handles per-direction
permission.

Startup logging emits a back-trace for each derived adjacency:

```
ws_kanban: derived neighbour ws_dev (declared in workspaces.yaml ws_dev.neighbors)
```

so operators can see why a workspace's tag includes URIs they didn't
explicitly write.

### 6.5 Per-edge metadata is deferred

v1 entries are plain URIs. The yaml schema reserves the option of
upgrading entries to objects:

```yaml
# v2 future, NOT in v1:
neighbors:
  - workspace:ws_kanban                              # v1 form, still valid
  - {target: chat:oc_legal, visibility: lazy}        # v2 form
  - {target: ws_archive, mode: read_only}            # v2 form
```

The parser will accept both forms when v2 lands. v1 emits no objects.

## 7. Hot-reload — hybrid policy

`workspaces.yaml` changes via fs_watch trigger `Esr.Topology` to
reload. Effect on active sessions:

| Yaml change | Behaviour |
|---|---|
| **Add neighbour** | Eager. `Esr.Topology` broadcasts `{:topology_neighbour_added, ws, uri}` via PubSub; CC peers in matching workspace add `uri` to their `reachable_set` immediately. Next prompt shows it. |
| **Remove neighbour** | Lazy. The runtime topology updates, but active sessions keep the URI in `reachable_set`. If the operator also removes the cap, the cap gate denies sends; otherwise the URI stays addressable until session ends. |

Rationale:
- Granting access shouldn't require restarting sessions (eager add).
- Revoking access shouldn't break in-flight conversations (lazy remove);
  cap gate is the authoritative enforcement layer.

PubSub topic naming follows the existing repo convention — strings,
not module-atom-style. Precedents:

- `"grants_changed:<principal_id>"` — `session_process.ex:96,145`,
  `capabilities/grants.ex:113`
- `"cli:channel/<sid>"` — `cc_process.ex:338`
- `"directive_ack:<id>"` — `peer_server.ex:391`

PR-C uses **`"topology:<workspace>"`** (one topic per workspace) so
CC peers subscribe only to events affecting their workspace.
`Phoenix.PubSub` instance is the existing `EsrWeb.PubSub`
(`application.ex:26`) — no new infrastructure.

Message shape: `{:topology_neighbour_added, ws, uri}` — same atom-+-tuple
convention as PR-A's `{:grants_changed, principal_id}`.

## 8. `<channel>` tag rendering

### 8.1 Today's tag fields

`build_channel_notification/2` (`cc_process.ex:351-374`) returns a map
with: `kind, source, chat_id, app_id, thread_id, message_id, user, ts,
content`. Two important details:

- `"source" => "feishu"` (line 357) is a **label string**, not an
  `esr://` URI. The actual `esr://` source URIs flow through upstream
  `:text` envelopes that don't reach cc_process today (see §5.1).
- `"user"` (line 370) currently maps from `meta.sender_id` — that's
  the open_id (`ou_xxx`), not a display name.

PR-C makes two breaking changes to the rendered tag:

1. Rename current `"user"` → `"user_id"`; add new `"user"` carrying
   the display name (resolved via FAA open_id → display name cache).
2. Add `"workspace"` attribute, looked up via
   `Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id)`
   (already exists at `workspaces/registry.ex:47-56`).

### 8.2 Format

⚠️ **API constraint discovered during PR-D implementation**:
`notifications/claude/channel` (Claude Code's experimental API used
to inject `<channel>` tags) only accepts **flat attributes** keyed
on `[A-Za-z0-9_]+`. Nested elements like `<reachable><actor/></reachable>`
are silently dropped. So the spec's original v1 design (nested element)
won't reach CC's prompt.

PR-D pivots the rendering to a **JSON-string attribute**:

```xml
<channel
    chat_id="oc_dev_room"
    app_id="feishu_app_dev"
    workspace="ws_dev"                                              ← NEW
    thread_id="..."
    user="林懿伦"                                                   ← display name (v2 work; alias of user_id today)
    user_id="ou_6b11..."                                            ← NEW: explicit open_id
    ts="2026-04-27T..."
    message_id="om_x100..."
    reachable='[{"uri":"esr://localhost/workspaces/ws_dev/chats/oc_dev_dm","name":"dev-dm"},{"uri":"esr://localhost/workspaces/ws_kanban/chats/oc_kanban_room","name":"kanban-room"},{"uri":"esr://localhost/users/ou_admin","name":"@admin"}]'>
  你好，给我一份周报
</channel>
```

The `reachable` attribute is omitted when the set is empty (avoids
prompt clutter for sessions with no neighbours). Claude reads JSON
natively in attributes, so the LLM ergonomics stay intact even
though the human-readable structure is denser than nested XML.

### 8.3 Display name resolution

`name` attribute on each `<actor>` element:

- **Chats**: `name` from `workspaces.yaml` `chats[].name` if set
  (new optional field per §6.2), else fall back to `chat_id` last 8
  chars (`...d42490`).
- **Users**: resolved via FAA's open_id → display_name cache (already
  exists in adapter; threading the display through to cc_process is
  part of PR-C).
- **Adapters**: `app_id` itself.
- **Sessions/peers**: tag or kind (future, when peer URIs are wired).

Display names are LLM ergonomic — the LLM can naturally write
"I'll post that to kanban-room" while still emitting the URI in tool
calls. Routing is URI-based; display name is presentation only.

### 8.3 Why XML

Three reasons:

1. **Anthropic-recommended for Claude**: XML tag delimitation has the
   highest LLM parsing accuracy among alternatives in our training
   data.
2. **Mixed structured + freeform body**: the message text is the
   element's text content; `<reachable>` is a structured child. YAML
   and JSON force the body into a string field (escaping, multi-line
   awkwardness).
3. **Existing investment**: PR-A and prior already use XML tags
   throughout cc_mcp parsing and scenario tests.

Hybrid forms (XML wrapping JSON for "structured part") were
considered and rejected; LLMs handle pure XML more reliably than
mixed-format payloads.

## 9. Implementation plan

### 9.1 PR-B — URI migration

Pure refactor, no behaviour change. Scope per §3.2. ~10-12 files,
~200-300 LOC. New `Esr.Uri` module + Python mirror.

Validation: existing unit + e2e suites must pass with zero failures.
A focused regex sweep to confirm no `adapter:<platform>/` literals
remain outside historical migration notes.

### 9.2 PR-C — topology + reachable_set

Builds on PR-B. Tasks (~8 commits, ~15-20 files, ~500-800 LOC):

| # | Task | Module(s) |
|---|---|---|
| C1 | yaml schema | `workspaces.yaml` (`neighbors:` field, optional `chats[].name`) + `workspaces/registry.ex` parser/loader |
| C2 | `Esr.Topology` module | new file `runtime/lib/esr/topology.ex`; `initial_seed/2`, `lookup_by_uri/1`, `neighbour_set/2`, symmetric closure, hot-reload broadcast |
| C3 | Upstream meta threading | `feishu_chat_proxy.ex` + `cc_proxy.ex` add `:source` and `:principal_id` to `meta` carried with `{:text, bytes, meta}` (see §5.1 path (a)) |
| C4 | CC peer state + BGP learn | `cc_process.ex` add `reachable_set: MapSet`; learn from `meta` in existing `{:text, bytes, meta}` clause (lines 142,145) |
| C5 | Tag rendering | `cc_process.ex:351 build_channel_notification/2` emits `<reachable>`, renames `user`→`user_id`, adds `user` (display) and `workspace` |
| C6 | Hot-reload | New `runtime/lib/esr/workspaces/watcher.ex` modeled on `capabilities/watcher.ex:21-22`; PubSub broadcast `"topology:<ws>"` |
| C7 | Unit tests | per module, including topology closure / BGP learn / tag render / watcher debounce |
| C8 | E2E scenario | extend `tests/e2e/scenarios/04_multi_app_routing.sh` (or new 05) asserting tag content + cross-app via topology |

Plus docs in same PR:
- This spec doc (already written)
- `docs/architecture.md` — add `Esr.Topology` + reachable_set
- `docs/notes/actor-topology-routing.md` — operator-facing
- `docs/notes/uri-migration.md` — covered by PR-B

### 9.3 Deferred — explicit decisions to NOT do v1

- **Per-edge metadata** (`mode`, `visibility`) — schema reserves the
  upgrade path; no implementation in v1.
- **Direct peer addressing** (`sessions/<sid>/peers/<kind>/<id>`) —
  URI shape defined but no caller wired; chat URI is sufficient
  for v1.
- **Cap-pre-checked tag exposure** — tag exposes all reachable URIs;
  cap gate fires at send time. Future option to filter by cap is a
  separate decision (would couple two layers).
- **Inter-agent RPC query** — would require new request/reply tool
  primitive + correlation-id + blocking semantics. Not needed for
  the workflow this spec targets.
- **Resolver layer** (LLM uses display name → runtime resolves URI)
  — not built; LLM addresses by URI, period.

## 10. Open questions

None blocking. The grill-me discussion covered Q4–Q21 across two
sessions. Remaining items are implementation choices (concrete data
structures, function signatures) that don't affect the design and
will be made during PR-C.

## 11. References

- Grill-me transcript: 2026-04-26 (DM `oc_d9b47511...`) Q1–Q21
- Builds on:
  - PR-A multi-app E2E: `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`
  - Lane A drop: `docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md`
- Capability spec: `docs/superpowers/specs/2026-04-20-esr-capabilities-design.md`
- Channel tag (PR-A): `runtime/lib/esr/peers/cc_process.ex` `build_channel_notification/2`
- Workspaces registry: `runtime/lib/esr/workspaces/registry.ex`
