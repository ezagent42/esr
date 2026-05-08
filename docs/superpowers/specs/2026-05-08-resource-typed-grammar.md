# Resource-Typed Grammar Refactor

**Spec id:** 2026-05-08-resource-typed-grammar
**Author:** Allen Woods + Claude
**Status:** rev-1 (draft, awaiting user review)
**Tracks:** rev-4 audit follow-ups #1, #2, #7 (`docs/manual-checks/2026-05-08-post-multi-instance-audit.md` § rev-4)
**Related specs:** 2026-05-08-session-first-default-resolution.md, 2026-05-08-plugin-command-registration.md (rev-3)

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
- Repurpose `/agent:list` to list **agent instances** in the chat-current session. Move the agent-type catalog under a more accurate name.
- Ship `/pty:list` + `/pty:attach pty=<id>` returning a signed-token URL that authenticates against `EsrWeb.PtySocket`. Close audit step #12 + plug the PTY auth hole as a single change.
- Provide a thin `/cc:tui name=<agent>` shortcut that resolves to a PTY id and reuses `/pty:attach`'s URL emission. Future plugins can ship analogous shortcuts.
- Migrate per-agent operations from `/session:*` to `/agent:*` — `/agent:add`, `/agent:remove`, `/agent:set-primary`, `/agent:primary` (read-only), `/agent:rename`.
- Migrate chat↔session binding from the `attach`/`detach` verb pair to `bind-chat`/`unbind-chat` for symmetry with the workspace family. Add `/session:switch` (change chat-current without unbinding) and slash-wire `/session:end` (destroy session).
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
| `/agent-type:list` | `agent_type_list` | (none) | **Renamed from old `/agent:list`** — lists plugin-declared agent types |
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

### 4.4 PtySocket signed-token auth

Replace today's `params["sid"]`-only auth (`pty_socket.ex:41-50`) with Phoenix.Token verification:

```elixir
def connect(params, socket, _connect_info) do
  with token when is_binary(token) <- params["token"],
       {:ok, {sid, pty_actor_id, _expires_at}} <-
         Phoenix.Token.verify(EsrWeb.Endpoint, "pty_attach", token, max_age: 600) do
    {:ok, assign(socket, sid: sid, pty_actor_id: pty_actor_id)}
  else
    _ -> :error
  end
end
```

`/pty:attach`'s command emits the token via `Phoenix.Token.sign(EsrWeb.Endpoint, "pty_attach", {sid, pty_actor_id, exp})` with a 10-minute expiry. The URL shape becomes:

```
https://<host>/sessions/<sid>/attach?token=<base64-signed>
```

The static `/sessions/:sid/attach` HTML shell forwards the token query param through to the WebSocket connect URL (`/attach_socket/websocket?token=…`). 1-line update to the AttachController template.

`check_origin: false` stays — it's needed for the cross-host xterm.js page; the signed token is the actual gate.

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
- **D3.** PtySocket gates on signed token, NOT on user identity. *Rationale:* the PTY URL is meant to be shareable (operator pastes it into another browser tab, sends to teammate via Feishu). Tying to a single user identity defeats the use case. The token's expiry + per-`pty_actor_id` scoping is the security guarantee.
- **D4.** Token expiry is 10 minutes. *Rationale:* long enough for an operator to click through after receiving the message; short enough that a leaked URL becomes useless within a session. Configurable via `Application.get_env(:esr, :pty_attach_token_ttl_seconds, 600)`.
- **D5.** Agent instance identity persists `actor_ids` on the `%Instance{}` struct. *Rationale:* see §4.5(a) — co-locate with the data it identifies; reduce cross-module coupling.
- **D6.** `/cc:tui` is the only plugin-shortcut shipped in this PR. Other agent types (future `/voice:tui`, `/web:browser`, etc.) are out of scope and land via the plugin-scoped command registration mechanism (rev-3 spec) when those plugins ship.
- **D7.** `/agent-type:list` (was `/agent:list`) keeps `category: "Agents"`. *Rationale:* operators looking under Agents in `/help` will find both the type catalog and the instance list; the category clusters them by intent.

## 6. Implementation surface

Estimate: ~580 LOC + ~400 LOC test = ~980 LOC.

| File | Change |
|---|---|
| `runtime/lib/esr/commands/session/list.ex` (new) | `Esr.Commands.Session.List` — reads `Esr.Resource.ChatScope.Registry` for chat-bound + `Esr.Scope.Registry` for admin-scope sessions |
| `runtime/lib/esr/commands/session/switch.ex` (new) | `Esr.Commands.Session.Switch` — updates ChatScope.Registry's `current_session` |
| `runtime/lib/esr/commands/session/bind_chat.ex` (new) | `Esr.Commands.Session.BindChat` — moved logic from `Esr.Commands.Session.Attach` |
| `runtime/lib/esr/commands/session/unbind_chat.ex` (new) | `Esr.Commands.Session.UnbindChat` — moved logic from `Esr.Commands.Session.Detach` |
| `runtime/lib/esr/commands/session/end.ex` (existing, slash-wire) | Already exists at `runtime/lib/esr/commands/scope/end.ex`; just needs slash entry in yaml |
| Delete: `runtime/lib/esr/commands/session/attach.ex` | Logic moves to bind_chat.ex; module deleted |
| Delete: `runtime/lib/esr/commands/session/detach.ex` | Logic moves to unbind_chat.ex; module deleted |
| `runtime/lib/esr/commands/agent/list.ex` (rewrite) | Now lists instances in chat-current session via `InstanceRegistry.list/2`. The old type-catalog logic moves to `agent_type/list.ex`. |
| `runtime/lib/esr/commands/agent_type/list.ex` (new) | Holds the old `/agent:list` content (type catalog) |
| `runtime/lib/esr/commands/agent/{add,remove,set_primary,primary,rename}.ex` (new ×5) | Each is a thin reframe of the existing `session/{add_agent,remove_agent,set_primary}` modules; primary + rename are net-new |
| Delete: `runtime/lib/esr/commands/session/{add_agent,remove_agent,set_primary}.ex` | Logic moves to `agent/*.ex` |
| `runtime/lib/esr/commands/pty/list.ex` (new) | Lists PTY actors per session via ActorQuery |
| `runtime/lib/esr/commands/pty/attach.ex` (new) | Generates signed token, returns URL |
| `runtime/lib/esr/commands/cc/tui.ex` (new) | Resolves agent-name → PTY id → calls Pty.Attach |
| Delete: `runtime/lib/esr/commands/attach.ex` | Orphan; URL-emission moves to `pty/attach.ex` |
| `runtime/lib/esr_web/pty_socket.ex` (modify) | `connect/1` now requires `params["token"]`; verifies via `Phoenix.Token.verify` |
| `runtime/lib/esr_web/controllers/attach_controller.ex` (modify) | Forward `?token=` query param into the WebSocket URL embedded in the HTML page |
| `runtime/lib/esr/entity/agent/instance.ex` (modify) | Add `actor_ids` field to struct |
| `runtime/lib/esr/entity/agent/instance_registry.ex` (modify) | Persist `actor_ids` on `add_instance_and_spawn`; expose `pty_actor_id_for/2` |
| `runtime/lib/esr/entity/slash_handler.ex` (modify) | Enrich not-found error for `@deprecated_slashes` map (add the 5 renamed slashes) |
| `runtime/lib/esr/commands/help.ex` (modify) | Add `Users` to category_order; add `Agent Types` separately if needed |
| `runtime/priv/slash-routes.default.yaml` (modify) | Add 14 new slashes; remove 5 old; update kind names |
| `runtime/test/esr/commands/session/{list,switch,bind_chat,unbind_chat}_test.exs` (new ×4) | TDD per command |
| `runtime/test/esr/commands/agent/{list,add,remove,set_primary,primary,rename}_test.exs` (new ×6) | TDD per command |
| `runtime/test/esr/commands/pty/{list,attach}_test.exs` (new ×2) | Including signed-token verify roundtrip |
| `runtime/test/esr/commands/cc/tui_test.exs` (new) | Integration test |
| `runtime/test/esr_web/pty_socket_test.exs` (modify) | Token verification: valid token connects; expired token rejected; missing token rejected; tampered token rejected |
| `tests/e2e/scenarios/20_resource_typed_grammar.sh` (new) | End-to-end: `/agent:add` → `/agent:list` → `/pty:list` → `/pty:attach` → curl URL → check 101 Switching Protocols (without xterm) |

## 7. Test plan (red→green per phase)

The implementation lands in 5 phases on a single branch + single PR (per project convention). Each phase ships its own commits but the e2e gate (scenario 20) runs only after the final phase:

1. **Phase A — `actor_ids` on `%Instance{}`** (foundation for `/cc:tui`). 1 module change + tests.
2. **Phase B — `/session:list` + slash-wire `/session:end` + add Users to /help category_order.** Pure additive, no removals.
3. **Phase C — Per-agent renames (`/agent:add`/`remove`/`set-primary`/`primary`/`rename`).** Migrate 3 existing modules + add 2 new. Delete the 3 `session/{add_agent,remove_agent,set_primary}.ex` files in the same commit. Update `slash-routes.default.yaml`. Update `slash_handler.ex` deprecation table.
4. **Phase D — Chat-binding renames (`/session:bind-chat`/`unbind-chat`/`switch`).** Move logic from `session/{attach,detach}.ex` into new modules. Delete old modules. Update yaml + deprecation table.
5. **Phase E — `/pty:*` family + `/cc:tui` + PtySocket auth.** New 4 commands + signed-token verification. Includes the `attach.ex` orphan deletion. e2e scenario 20 lands here.

Each phase commits independently. No aggregation across phases — the dispatcher must remain functional after each phase.

## 8. Invariants (verified by tests)

- **I1.** Every operator-visible slash that operates on agent instances is under `/agent:*`. Verify by grep: `grep -E "^\s*/session:(add-agent|remove-agent|set-primary|rename-agent|detach-agent)" runtime/priv/slash-routes.default.yaml` returns nothing.
- **I2.** Every operator-visible slash that emits a TUI URL is under `/pty:*` or a registered plugin shortcut. Today only `/pty:attach` and `/cc:tui` exist; plugins can grow `/<plugin>:tui` per rev-3 spec.
- **I3.** `EsrWeb.PtySocket` rejects connections without a valid Phoenix.Token in the `?token=` query param. Verified by `pty_socket_test.exs` 4 cases (valid / expired / missing / tampered).
- **I4.** `/agent:list` (chat-current session, no args) returns agent instances, NOT agent types. Verified by e2e scenario 20: spawn cc:alice + cc:bob, `/agent:list` returns 2 lines containing "alice" and "bob".
- **I5.** Each renamed slash returns a structured error pointing at the new form when invoked by an operator. Verified by `slash_handler_test.exs` cases for the 5 deprecated slashes.

## 9. Open questions for review

- **Q1.** Is `/agent-type:list` the right name for the relocated type catalog, or should it be `/plugin:agent-types`? *Recommend: `/agent-type:list`* — keeps the `<resource>:<verb>` shape consistent (P1); plugins are not the only source of agent types in principle (a future core-defined type would also live there).
- **Q2.** Should `/cc:tui` be in core (current spec) or in the `claude_code` plugin's manifest? Per rev-3 spec D3, plugin commands belong in plugin manifests. But `claude_code` is currently considered "core" because it's always installed. *Recommend: ship in core for this PR, refactor under `claude_code` plugin's `slash_routes:` block in a follow-up after the rev-3 mechanism gets exercised by another plugin first.*
- **Q3.** PtySocket auth applies to ALL connections after this PR — including any existing operator who may have an open browser tab on the old (unauthenticated) URL. They'll see the WebSocket disconnect. *Acceptable risk?* The system is in dev, no production users.
- **Q4.** Do we keep `Esr.Commands.Scope.List` (the legacy `internal_kind: session_list` impl)? It returns a different shape (active/targets/branches) than the new `Esr.Commands.Session.List` would. *Recommend: deprecate the internal_kind in this PR + delete the file.* The escript path can use the new slash via the standard kind-dispatch; nothing relies on the structured `branches[]` shape today.

## 10. Migration impact summary

| User-visible change | Operator action required |
|---|---|
| `esr session add-agent type=cc name=alice` → `esr agent add type=cc name=alice` | Update muscle memory; `/help` shows the new form |
| `esr session set-primary name=alice` → `esr agent set-primary name=alice` | Same |
| `esr session attach session=<uuid>` (chat-binding) → `esr session bind-chat session=<uuid>` | Same; old form returns hint at new form |
| `/agent:list` now lists running instances | Old type-catalog use case → `/agent-type:list` (1-time relearn; type-catalog rarely consulted in normal flow) |
| Browser TUI URLs now require `?token=…` | Old URLs (without token) stop working; operator gets a fresh URL via `/pty:attach` (same flow as before, just authenticated) |
| New `/pty:list`, `/pty:attach`, `/cc:tui`, `/agent:rename`, `/agent:primary`, `/session:list`, `/session:switch` | Pure additions; no muscle-memory disruption |

## 11. Out-of-scope (future work, tracked elsewhere)

- Canonical command-list reference doc (rev-4 audit task #8): an `esr admin describe-grammar --format=markdown` generator that produces `docs/grammar/commands.md` from yaml + plugin manifests + EsrWeb router. Independent of this spec.
- Per-PTY caps (`pty:<actor_id>/attach`) creation/management: this spec uses the cap string in command-level checks but doesn't ship a `/cap:grant` flow for PTY caps. Today PTY caps are auto-granted to the session creator; cross-user PTY-share is a separate feature.
- Multi-PTY-per-agent support: explicitly excluded; spec assumes 1 PTY per agent (true today via M-2.6's `(CC, PTY)` `:one_for_all`).
