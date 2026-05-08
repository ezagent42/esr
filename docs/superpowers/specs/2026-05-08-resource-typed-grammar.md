# Resource-Typed Grammar Refactor

**Spec id:** 2026-05-08-resource-typed-grammar
**Author:** Allen Woods + Claude
**Status:** rev-3 (metamodel re-grounded: **Realm = class, Session = instance** — concepts.md to be updated)
**Tracks:** rev-4 audit follow-ups #1, #2, #7 (`docs/manual-checks/2026-05-08-post-multi-instance-audit.md` § rev-4)
**Related specs:** 2026-05-08-session-first-default-resolution.md, 2026-05-08-plugin-command-registration.md (rev-3)

## 0. rev-3 changelog (2026-05-08) — metamodel re-grounding

After spec rev-2 was committed, deeper discussion surfaced that the entire Scope-vs-Session vocabulary needed inversion. **rev-3 swaps the metamodel mapping:**

| Layer | Old (concepts.md current) | New (rev-3) |
|---|---|---|
| **Class / declarative** | Session | **Realm** (new word) |
| **Instance / runtime** | Scope | **Session** (operator-aligned) |

**Rationale:** operators say `/session:new` meaning "create a new instance" — that's instance-flavored vocabulary. concepts.md's current "Session = class" mapping fights operator intuition; "Scope = instance" maps to neither everyday English nor programming usage of "scope". The swap aligns code AND operator vocabulary on instance, and introduces "Realm" for the class layer ("Realm of admin operations", "the workspace Realm" reads naturally as kind/category).

The metamodel becomes:

- **4 runtime primitives**: **Session**, Entity, Resource, Interface (was: Scope, Entity, Resource, Interface)
- **1 declarative primitive**: **Realm** (was: Session)
- "类比 OOP：**Realm 是 class、Session 是 instance**" (was: Scope 是 instance, Session 是 class)
- `use SomeRealm` produces a Session

**Carried forward from rev-1/rev-2 (unchanged):**

- **Q1.** `/plugin:agent-types` for the relocated agent-type catalog.
- **Q2.** Drop PtySocket signed-token auth from this PR (tracked as future hardening).
- **Q3.** `/cc:tui` ships in the claude_code plugin per rev-3 plugin-cmd D3.

**rev-3 corrections (this revision):**

- **Q4-revised.** A pre-cleanup PR ships **before** this spec implements, with three concerns bundled:
  1. **`Esr.Scope.* → Esr.Session.*`** rename for runtime modules (~7 modules: `Process`, `Router`, `Supervisor`, `AgentSupervisor`, `AgentInstanceSupervisor`, `Admin`, `Admin.Process`).
  2. **`Esr.Commands.Scope.* → Esr.Commands.Session.*`** rename for the 6 admin/escript command modules (`New`, `End`, `Switch`, `List`, `BranchNew`, `BranchEnd`). The `Esr.Commands.Session.*` modules added in PR #248 era (`Attach`, `Detach`, `Share`, `AddAgent`, `RemoveAgent`, `SetPrimary`, `New`) are correctly named under the new mapping (they create Session instances) and stay. The collision case `Session.New (103 LOC, post-PR-248) vs Scope.New (449 LOC, M-1..M-5 era)` resolves by **merging** — keep the 449-LOC full-spawn impl as canonical `Esr.Commands.Session.New`.
  3. **`Esr.Resource.ChatScope.Registry` SPLIT** into two registries (the moduledoc itself flags "Two responsibilities, one GenServer" as a known design smell):
     - **Responsibility 1**: `(chat_id, app_id) → session_id` chat-routing → moves to `Esr.Session.ChatRouting.Registry`. Rationale: chat is a Channel Resource (per concepts.md §四), but the chat→session binding is session-side state.
     - **Responsibility 2**: `(env, username, workspace, name) → session_id` URI uniqueness → moves to `Esr.Session.NameIndex.Registry` (mirrors `Esr.Resource.Workspace.NameIndex`).
- **Companion concepts.md PR ships first** — re-grounds the metamodel (Scope→Session, Session→Realm) so the code rename has documented metamodel backing. Doc-only, ships independently.
- **§6 implementation surface** updated — every new module added by this spec uses `Esr.Commands.Session.*` (post-cleanup canonical name).

**Slash surface unchanged.** Operator vocabulary `/session:*` was already aligned with instance semantics; rev-3 just makes the code agree.

## 1. Problem statement

Three operator-visible gaps and a structural mis-naming exist in the slash-command surface today:

1. **`/session:list` doesn't exist.** `/session:attach`'s description literally says "用 /session:list 查 UUID" (`runtime/priv/slash-routes.default.yaml:320`), but the slash is unwired (`slash-routes.default.yaml:348-349` confirms it's deferred). The legacy `Esr.Commands.Scope.List` exists as `internal_kind: session_list` only — escript-callable but not chat-callable.

2. **`/agent:list` is mis-named.** Today it lists agent **types** declared by enabled plugins (`runtime/lib/esr/commands/agent/list.ex:1-36` reads `Esr.Entity.Agent.Registry.list_agents/0` — no session_id arg). After M-2 multi-instance, what an operator wants from `/agent:list` is **the running instances inside the chat-current session** (e.g. `cc:alice`, `cc:bob`). The type catalog is now plugin metadata, not a workflow command.

3. **No PTY URL emitter.** Phase 6 colon-namespace cutover deleted the `/attach` slash. `Esr.Commands.Attach` (`runtime/lib/esr/commands/attach.ex:24-39`) still exists and emits an `EsrWeb.PtySocket` URL, but it's orphaned — wired only as `internal_kind: attach` (`slash-routes.default.yaml:674-676`), no slash key, not in `/help`. Operators cannot get a clickable browser-TUI URL from chat.

4. **`EsrWeb.PtySocket` has zero authentication.** `runtime/lib/esr_web/pty_socket.ex:41-50` accepts any non-empty `sid` query parameter — no signed token, no user binding, no cap check. `check_origin: false`. Any URL leak gives full PTY input/output to the leaker.

5. **Per-agent commands are mis-located.** `/session:add-agent`, `/session:remove-agent`, `/session:set-primary` operate on agent instances, not on sessions. Per the rev-4 audit (P1: "resource axis follows the operand"), they belong under `/agent:*`.

6. **`/session:attach` and `/session:detach` are mis-named.** They manage chat↔session binding, not terminal access. The verb `attach` belongs to PTY (returns terminal URL); chat-binding should mirror `/workspace:bind-chat` / `/workspace:unbind-chat`.

## 2. Goals

- Wire `/session:list` so the documentation gap on `/session:attach`'s description (and the rev-4 audit gap A) closes.
- Repurpose `/agent:list` to list **agent instances** in the chat-current session. Move the agent-type catalog to `/plugin:agent-types`.
- Ship `/pty:list` + `/pty:attach pty=<id>` returning a clickable PTY URL. Close audit step #12 (operator can get a TUI URL again).
- Provide a thin `/cc:tui name=<agent>` shortcut **in the claude_code plugin** that resolves to a PTY id and reuses `/pty:attach`'s URL emission. Future plugins can ship analogous shortcuts via the rev-3 mechanism.
- Migrate per-agent operations from `/session:*` to `/agent:*` — `/agent:add`, `/agent:remove`, `/agent:set-primary`, `/agent:primary` (read-only), `/agent:rename`.
- Migrate chat↔session binding from the `attach`/`detach` verb pair to `bind-chat`/`unbind-chat` for symmetry with the workspace family. Slash-wire the existing `Esr.Commands.Session.Switch` (change chat-current without unbinding) and `Esr.Commands.Session.End` (destroy session).
- Add a "Users" category to `/help`'s explicit category order so `/user:*` slashes don't fall into the "其他" default bucket.

## 3. Non-goals

- **No deprecation aliases for renamed slashes.** The moment this PR lands, `/session:add-agent` returns an error pointing at `/agent:add`. Per project convention (rev-3 `2026-05-08-plugin-command-registration.md` D4 + memory rule "let-it-crash; no workarounds/whitelists"), back-compat shims are forbidden. The error response is the migration aid.
- **No hot-migration of capability strings.** Existing caps (`session:<uuid>/attach`, etc.) keep their string shape; only the *commands* checking them change. A separate spec can rename caps later if desired.
- **No new HTTP routes beyond what `EsrWeb.PtySocket` already mounts.** Token signing happens inside the existing socket connect path.
- **No multi-PTY-per-agent support.** Each agent instance is assumed to have exactly one PTY actor (which is true today — `(CC, PTY)` `:one_for_all` per M-2.6).

## 4. Design

### 4.1 The 4 principles (formalized from rev-4 audit)

- **P1 — Resource axis follows the OPERAND.** A command operating on resource X is `/<X>:<verb>`, regardless of what resource X lives inside.
- **P2 — Lists return their own resource.** `/session:list` returns sessions. `/agent:list` returns agent instances. No `/session:list-agents`.
- **P3 — `attach` is a PTY operation.** Returns a WebSocket URL signed for one specific PTY actor. Chat-binding uses different verbs (`bind-chat`/`unbind-chat`/`switch`).
- **P4 — One canonical command-list reference.** Tracked separately as audit task #8 (rev-4 roadmap); not part of this spec but the slash-routes yaml + plugin manifest's `slash_routes:` blocks remain the source of truth.

### 4.2 New slashes (this PR)

| Slash | Kind | Permission | Description |
|---|---|---|---|
| `/session:list` | `session_list` | `session:default/read` | Lists sessions in chat scope (chat-bound + admin-scope) |
| `/session:switch` | `session_switch` | (none — chat-bound) | Change chat-current session without unbinding others |
| `/session:bind-chat` | `session_bind_chat` | `session:<uuid>/attach` | Bind a session to the current chat (replaces `/session:attach`) |
| `/session:unbind-chat` | `session_unbind_chat` | (none) | Unbind from chat (replaces `/session:detach`) |
| `/session:end` | `session_end` | `session:<uuid>/end` | Destroy session (was internal_kind only) |
| `/agent:list` | `agent_list` | (none — chat-bound) | **Repurposed**: lists agent **instances** in chat-current session |
| `/agent:add` | `agent_add` | `session:<uuid>/spawn` | Replaces `/session:add-agent` |
| `/agent:remove` | `agent_remove` | `session:<uuid>/spawn` | Replaces `/session:remove-agent` |
| `/agent:set-primary` | `agent_set_primary` | `session:<uuid>/spawn` | Replaces `/session:set-primary` |
| `/agent:primary` | `agent_primary` | (none — chat-bound) | Read-only: show primary agent name |
| `/agent:rename` | `agent_rename` | `session:<uuid>/spawn` | Per-agent rename (no current equivalent) |
| `/plugin:agent-types` | `plugin_agent_types` | (none) | **Renamed from old `/agent:list`** — lists agent types declared by enabled plugins |
| `/pty:list` | `pty_list` | (none — chat-bound) | Lists PTY actors for chat-current session |
| `/pty:attach` | `pty_attach` | `pty:<actor_id>/attach` | Returns signed-token WebSocket URL |
| `/cc:tui` | `cc_tui` | `pty:<actor_id>/attach` | Thin shortcut: agent-name → PTY id → `/pty:attach` |

### 4.3 Removed slashes (no back-compat)

| Old slash | Replacement | Migration note |
|---|---|---|
| `/session:add-agent` | `/agent:add` | Hard-cutover. Error response says: "use `/agent:add type=… name=…`" |
| `/session:remove-agent` | `/agent:remove` | Same |
| `/session:set-primary` | `/agent:set-primary` | Same |
| `/session:attach` | `/session:bind-chat` (chat) OR `/pty:attach` (URL) | The old slash conflated two concerns; error message resolves which the operator wanted from arg shape (`session=<uuid>` → bind-chat; `pty=<id>` → pty:attach) |
| `/session:detach` | `/session:unbind-chat` | Same |

The "removed" slashes don't appear in `slash-routes.default.yaml` anymore. The dispatcher returns `:not_found`. The operator-facing error message is generated by `Esr.Entity.SlashHandler` (existing not-found path) — needs a one-time enrichment to suggest replacements for known-renamed slashes (a small lookup table in slash_handler.ex).

### 4.4 PtySocket auth — out of scope (rev-2)

PtySocket's `connect/1` (`pty_socket.ex:41-50`) accepts any non-empty `sid` query parameter as auth. This is a real security gap (anyone with network reach + sid string can drive the PTY), but for a single-operator-on-Tailscale deployment the practical risk is bounded by network access control.

Tracked as future hardening work in `docs/futures/todo.md` (key: `pty_attach_security_hardening`); not implemented in this spec. The `/pty:attach` command this spec ships emits an unauthenticated URL of the same shape today's orphan `Esr.Commands.Attach` produces:

```
http://<host>/sessions/<sid>/attach
```

When the hardening pass lands, only the PtySocket connect path + the URL emitter need updating — the slash + plugin command surfaces stay as-is.

### 4.5 PTY-id lookup by agent name

Today's `Esr.Entity.Agent.InstanceRegistry` doesn't persist `actor_ids` on `%Instance{}`. They surface only as a side-channel return from `add_instance_and_spawn/2`. For `/cc:tui name=<agent>` to resolve agent → PTY id, we need a lookup.

Two options:

- **(a) Add `actor_ids` field to `%Instance{}` struct + persist in the registry's ETS table.** Updates: `instance.ex:25-32` adds the field; `instance_registry.ex:87` populates on `add_instance_and_spawn`. ~30 LOC.
- **(b) Use the existing `Esr.Entity.Agent.ActorQuery` module (M-1 spec) to index by name.** ActorQuery already maps `(session_id, name) → pid`. Add `pty_actor_id_for/2` that resolves `(session_id, name)` to the PTY actor's id (the registry's by-name index already includes the PTY peer).

**Recommend (a)** — fewer cross-module dependencies, and `actor_ids` belong on the instance. ActorQuery stays as a runtime-pid lookup; persistent identity belongs on the struct.

### 4.6 `/help` category additions

Add to `runtime/lib/esr/commands/help.ex:46-54`:

```elixir
defp category_order("Users"), do: 1   # before Workspaces
defp category_order("PTY"), do: 5     # already present
```

`/user:use` declares `category: "Users"` in slash-routes yaml today; without the entry above it falls into the default-50 bucket. Adding it ordered between 诊断 and Workspaces makes `/help` rendering match operator mental model.

## 5. Decisions

- **D1.** Hard-cutover for renamed slashes. *Rationale:* matches plugin-scoped command registration spec rev-3 D4. Soft deprecation aliases stack cognitive cost on every operator (`/help` shows both, autocomplete ambiguous, etc.) and "let-it-crash" memory rule applies.
- **D2.** `slash_handler.ex` not-found path enriches the error message for known-renamed slashes. Lookup table is a small `@deprecated_slashes %{"/session:add-agent" => "/agent:add", …}` private map. *Rationale:* the dispatcher already returns "unknown slash" for typos; enriching the small known-renamed subset is one error-message expansion, not a back-compat code path.
- **D3.** PtySocket auth is out of scope for this PR (rev-2). *Rationale:* single-operator-on-Tailscale deployment doesn't need it today; locating the work in a future security-hardening pass keeps this PR focused on grammar refactor. The unauthenticated `?sid=…` URL stays as-is.
- **D4.** Agent instance identity persists `actor_ids` on the `%Instance{}` struct. *Rationale:* see §4.5(a) — co-locate with the data it identifies; reduce cross-module coupling.
- **D5.** `/cc:tui` ships in the **claude_code plugin**, not core. *Rationale:* per 2026-05-08-plugin-command-registration spec rev-3 D3 ("Per-plugin namespace prefix is mandatory"). `/cc:tui` becomes the second real consumer of the rev-3 mechanism (after feishu's bind/unbind/notify), validating the plugin-scoped command registration end-to-end again. Module: `Esr.Plugins.ClaudeCode.Commands.Tui`. Manifest entry under `runtime/lib/esr/plugins/claude_code/manifest.yaml`'s `slash_routes:` block.
- **D6.** `/plugin:agent-types` (was `/agent:list`) keeps `category: "Plugins"`. *Rationale:* the operation is plugin metadata access; operators looking under Plugins in `/help` find plugin-related state including declared agent types.
- **D7.** `Esr.Scope.* → Esr.Session.*` module rename ships in a SEPARATE PR before this spec implements. *Rationale:* "Scope" is the M-1..M-5 era code name for what's now operator-conceptually called "Session"; the slash surface migrated long ago but module names lag. Bundling the rename with the grammar refactor mixes mechanical sed work with semantic command additions, making review harder. Pre-rename PR is purely mechanical (sed + slash-routes yaml `command_module:` updates + `mix test` + e2e 14/18/19); zero behavior change.

## 6. Implementation surface

Estimate (rev-3, post-cleanup): ~480 LOC + ~330 LOC test = ~810 LOC. (This is the grammar-refactor PR only; the cleanup PR's own LOC is ~600-800 mostly mechanical.)

**Prerequisites (two independent PRs ship before this spec implements):**

1. **concepts.md PR** — re-grounds the metamodel (Scope→Session for instance role, Session→Realm for class role). Doc-only; ~30 min.
2. **Cleanup PR** — three bundled changes (~3-4 hours):
   - `Esr.Scope.* → Esr.Session.*` (runtime layer, ~7 modules + ~80 references)
   - `Esr.Commands.Scope.* → Esr.Commands.Session.*` (command modules, ~6 modules) + merge `Session.New (103) + Scope.New (449)` into canonical `Session.New (449)`
   - Split `Esr.Resource.ChatScope.Registry` → `Esr.Session.ChatRouting.Registry` + `Esr.Session.NameIndex.Registry`

This table assumes both prerequisites have landed and the codebase uses `Esr.Session.*` consistently:

| File | Change |
|---|---|
| `runtime/lib/esr/commands/session/list.ex` (new) | `Esr.Commands.Session.List` — replaces the legacy `Esr.Commands.Scope.List` (post-rename: `Esr.Commands.Session.List` already exists for kind `session_list`; rewrite its body to return chat-bound + admin-scope sessions in a uniform shape) |
| `runtime/lib/esr/commands/session/switch.ex` (existing, slash-wire) | `Esr.Commands.Session.Switch` (post-rename) already exists (kind `session_switch`); just needs slash entry in yaml |
| `runtime/lib/esr/commands/session/bind_chat.ex` (new) | `Esr.Commands.Session.BindChat` — moves logic from existing `Esr.Commands.Session.Attach` |
| `runtime/lib/esr/commands/session/unbind_chat.ex` (new) | `Esr.Commands.Session.UnbindChat` — moves logic from existing `Esr.Commands.Session.Detach` |
| `runtime/lib/esr/commands/session/end.ex` (existing, slash-wire) | Already exists post-rename; just needs slash entry in yaml |
| Delete: `runtime/lib/esr/commands/session/attach.ex` | Logic moves to bind_chat.ex; module deleted |
| Delete: `runtime/lib/esr/commands/session/detach.ex` | Logic moves to unbind_chat.ex; module deleted |
| `runtime/lib/esr/commands/agent/list.ex` (rewrite) | Now lists instances in chat-current session via `InstanceRegistry.list/2`. Old type-catalog logic moves into the plugin namespace |
| `runtime/lib/esr/commands/plugin/agent_types.ex` (new) | `Esr.Commands.Plugin.AgentTypes` — holds the old `/agent:list` content (lists `Esr.Entity.Agent.Registry.list_agents/0` type catalog) |
| `runtime/lib/esr/commands/agent/{add,remove,set_primary,primary,rename}.ex` (new ×5) | Each is a thin reframe of the existing `session/{add_agent,remove_agent,set_primary}` modules; `primary` + `rename` are net-new |
| Delete: `runtime/lib/esr/commands/session/{add_agent,remove_agent,set_primary}.ex` | Logic moves to `agent/*.ex` |
| `runtime/lib/esr/commands/pty/list.ex` (new) | Lists PTY actors per session via `Esr.Entity.Agent.InstanceRegistry.list/2` (uses the new `actor_ids` field from D4) |
| `runtime/lib/esr/commands/pty/attach.ex` (new) | Returns the unauthenticated URL (today's `Esr.Commands.Attach` logic, properly slash-wired) |
| `runtime/lib/esr/plugins/claude_code/commands/tui.ex` (new) | `Esr.Plugins.ClaudeCode.Commands.Tui` — resolves agent-name → PTY id → calls `Esr.Commands.Pty.Attach` (D5: lives in plugin per rev-3 D3) |
| `runtime/lib/esr/plugins/claude_code/manifest.yaml` (modify) | Add `slash_routes:` block declaring `/cc:tui` (per rev-3 mechanism — second real consumer) |
| Delete: `runtime/lib/esr/commands/attach.ex` | Orphan URL-emitter; functionality moves to `pty/attach.ex` |
| `runtime/lib/esr/entity/agent/instance.ex` (modify) | Add `actor_ids` field to struct (D4) |
| `runtime/lib/esr/entity/agent/instance_registry.ex` (modify) | Persist `actor_ids` on `add_instance_and_spawn`; expose `pty_actor_id_for/2` |
| `runtime/lib/esr/entity/slash_handler.ex` (modify) | Enrich not-found error for `@deprecated_slashes` map (the 5 renamed slashes) |
| `runtime/lib/esr/commands/help.ex` (modify) | Add `Users` to category_order |
| `runtime/priv/slash-routes.default.yaml` (modify) | Add 13 new slashes (`/session:list`, `/session:switch`, `/session:bind-chat`, `/session:unbind-chat`, `/session:end`, `/agent:list` repurposed, `/agent:add`, `/agent:remove`, `/agent:set-primary`, `/agent:primary`, `/agent:rename`, `/plugin:agent-types`, `/pty:list`, `/pty:attach`); remove 5 old |
| `runtime/test/esr/commands/session/{list,bind_chat,unbind_chat}_test.exs` (new ×3) | TDD per command (`switch` already has tests post-rename) |
| `runtime/test/esr/commands/agent/{list,add,remove,set_primary,primary,rename}_test.exs` (new ×6) | TDD per command |
| `runtime/test/esr/commands/plugin/agent_types_test.exs` (new) | Type catalog test |
| `runtime/test/esr/commands/pty/{list,attach}_test.exs` (new ×2) | Pty list + URL emit |
| `runtime/test/esr/plugins/claude_code/commands/tui_test.exs` (new) | Integration test for /cc:tui resolving agent name → PTY id → URL |
| `runtime/test/esr/entity/slash_handler_test.exs` (modify) | Cases for the 5 renamed-slash error-message enrichment |
| `tests/e2e/scenarios/20_resource_typed_grammar.sh` (new) | End-to-end: `/agent:add` → `/agent:list` returns instances → `/pty:list` returns the spawned PTYs → `/pty:attach pty=<id>` returns clickable URL → curl URL → check 101 Switching Protocols (without xterm) |

## 7. Test plan (red→green per phase)

The implementation lands in 5 phases on a single branch + single PR (assumes the Scope→Session pre-rename PR has merged). Each phase ships its own commits; the e2e gate (scenario 20) runs only after the final phase:

1. **Phase A — `actor_ids` on `%Instance{}`** (foundation for `/cc:tui`). 1 module change + tests.
2. **Phase B — `/session:list` + slash-wire `/session:switch` + slash-wire `/session:end` + add Users to /help category_order.** Pure additive, no removals.
3. **Phase C — Per-agent renames (`/agent:add`/`remove`/`set-primary`/`primary`/`rename`) + repurpose `/agent:list` + new `/plugin:agent-types`.** Migrate 3 existing modules + add 2 new (`primary`, `rename`). Delete the 3 `session/{add_agent,remove_agent,set_primary}.ex` files in the same commit. Update `slash-routes.default.yaml`. Update `slash_handler.ex` deprecation table.
4. **Phase D — Chat-binding renames (`/session:bind-chat`/`unbind-chat`).** Move logic from `session/{attach,detach}.ex` into new modules. Delete old modules. Update yaml + deprecation table.
5. **Phase E — `/pty:*` family + `/cc:tui` (in claude_code plugin).** New 2 core commands (`pty:list`, `pty:attach`) + 1 plugin command (`cc:tui` via claude_code manifest's `slash_routes:` block per rev-3 mechanism). Includes the `Esr.Commands.Attach` orphan deletion. e2e scenario 20 lands here.

Each phase commits independently. No aggregation across phases — the dispatcher must remain functional after each phase.

## 8. Invariants (verified by tests)

- **I1.** Every operator-visible slash that operates on agent instances is under `/agent:*`. Verify by grep: `grep -E "^\s*/session:(add-agent|remove-agent|set-primary|rename-agent|detach-agent)" runtime/priv/slash-routes.default.yaml` returns nothing.
- **I2.** Every operator-visible slash that emits a TUI URL is under `/pty:*` or a registered plugin shortcut. After this PR `/pty:attach` (core) + `/cc:tui` (claude_code plugin) exist; future plugins grow `/<plugin>:tui` per rev-3 spec.
- **I3.** `/agent:list` (chat-current session, no args) returns agent instances, NOT agent types. Verified by e2e scenario 20: spawn cc:alice + cc:bob, `/agent:list` returns 2 lines containing "alice" and "bob"; `/plugin:agent-types` returns "cc" (the type catalog).
- **I4.** Each renamed slash returns a structured error pointing at the new form when invoked by an operator. Verified by `slash_handler_test.exs` cases for the 5 deprecated slashes (`/session:add-agent` → `/agent:add`, etc.).
- **I5.** `/cc:tui` is registered via the claude_code plugin's manifest `slash_routes:` block (rev-3 mechanism). Verified by inspecting `Esr.Resource.SlashRoute.Registry` overlay state — `/cc:tui` appears as a feishu-sibling overlay entry, not in the base `slash-routes.default.yaml`.

## 9. Open questions resolved (rev-3)

All 4 open questions from rev-1 + rev-2 resolved by user 2026-05-08:

- **Q1 ✓** `/plugin:agent-types` (was `/agent-type:list` in rev-1). Anchored under existing `/plugin:` namespace; agent types are plugin metadata.
- **Q2 ✓** `/cc:tui` ships in claude_code plugin (was "ship in core" in rev-1). Becomes the second real consumer of plugin-scoped command registration mechanism.
- **Q3 ✓** PtySocket signed-token auth deferred (was "in this PR" in rev-1). Tracked as future hardening (`pty_attach_security_hardening` in `docs/futures/todo.md`).
- **Q4 ✓ (rev-3)** Metamodel inverted: **Realm = class, Session = instance** (was: Session = class, Scope = instance). `Esr.Scope.* → Esr.Session.*` rename + commands rename + ChatScope split, all in one cleanup PR after the concepts.md update PR. See §0 changelog for full rationale.

## 10. Migration impact summary

| User-visible change | Operator action required |
|---|---|
| `esr session add-agent type=cc name=alice` → `esr agent add type=cc name=alice` | Update muscle memory; `/help` shows the new form |
| `esr session set-primary name=alice` → `esr agent set-primary name=alice` | Same |
| `esr session attach session=<uuid>` (chat-binding) → `esr session bind-chat session=<uuid>` | Same; old form returns hint at new form |
| `/agent:list` now lists running instances | Old type-catalog use case → `/plugin:agent-types` (1-time relearn; type-catalog rarely consulted in normal flow) |
| New `/pty:list`, `/pty:attach`, `/cc:tui`, `/agent:rename`, `/agent:primary`, `/session:list`, `/session:switch` slash | Pure additions; no muscle-memory disruption |
| Metamodel + module rename (pre-cleanup PRs): Scope→Session (instance), Session→Realm (class). `Esr.Scope.*` → `Esr.Session.*`, `Esr.Resource.ChatScope.Registry` splits into `Esr.Session.ChatRouting.Registry` + `Esr.Session.NameIndex.Registry`. | No operator-visible change; only affects internal tooling that grep'd old module names |

## 11. Out-of-scope (future work, tracked elsewhere)

- **PtySocket signed-token auth** (`pty_attach_security_hardening` in `docs/futures/todo.md`): replace today's `?sid=`-only auth with Phoenix.Token + 10min TTL. ~30 LOC + tests when it lands. Stays out of this PR per rev-2 D3.
- **Canonical command-list reference doc** (rev-4 audit task #8): an `esr admin describe-grammar --format=markdown` generator that produces `docs/grammar/commands.md` from yaml + plugin manifests + EsrWeb router. Independent of this spec.
- **Multi-PTY-per-agent support**: explicitly excluded; spec assumes 1 PTY per agent (true today via M-2.6's `(CC, PTY)` `:one_for_all`).
