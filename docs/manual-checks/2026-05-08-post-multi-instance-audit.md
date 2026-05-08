# Post multi-instance routing audit — 2026-05-08

**Operator-proposed journey** (12 steps, original from 2026-05-06 rev-3) vs **shipped surface** as of `origin/dev` post PR #263 (session-first default + plugin-scoped command registration).

> **rev-4 update (2026-05-08, post PR #263):** session-first migration (#5) and plugin-scoped command registration (#6 rev-3) closed end-to-end. New section [§ rev-4 — resource-typed grammar revision](#rev-4--resource-typed-grammar-revision-2026-05-08) reframes the previously-listed gaps A/B/C against four operator-stated grammar principles. The original "newly-surfaced gaps" proposals were partially incorrect (mis-located on the `/session:*` axis instead of the resource axis); see rev-4 for the revised plan.

> **Companion file:** Chinese version at
> [`2026-05-08-post-multi-instance-audit.zh_cn.md`](2026-05-08-post-multi-instance-audit.zh_cn.md).
>
> **Predecessor:** [`2026-05-06-bootstrap-flow-audit.md`](2026-05-06-bootstrap-flow-audit.md)
> — 12-step journey baseline. This audit re-scores against the same 12
> steps after Phase 6 colon-namespace cutover, Phase 7 plugin config,
> HR-1..HR-4 hot-reload, PR #248 `/session:*` commands, and PR #261
> multi-instance routing cleanup all landed.

## Methodology

Same three-axis scoring as the predecessor audit (I = interface, F = function, G = grammar). Symbols: ✅ yes · ⚠️ partial · ❌ no.

Scope: `runtime/priv/slash-routes.default.yaml`, `runtime/lib/esr/cli/main.ex`, `runtime/lib/esr/commands/**`, `runtime/lib/esr/resource/capability/supervisor.ex`, `runtime/lib/esr/entity/agent/instance_registry.ex` (M-2.7), `runtime/lib/esr/scope/agent_supervisor.ex` (M-2.6). Doc cross-refs cite `file_path:line` per the project convention.

## Headline table — re-scored

| # | Operator types | I | F | G | Net | Δ vs 2026-05-06 |
|---|---|---|---|---|---|---|
| 1 | `esr daemon start` | ✅ | ✅ | ✅ | works | unchanged |
| 2 | `esr add user linyilun`（auto-admin） | ✅ | ⚠️ | ⚠️ | grammar fixed via colon-namespace; auto-admin still env-driven | grammar improved |
| 3 | `esr plugin install feishu` | ✅ | ⚠️ | ⚠️ | colon-namespace shipped; install verb still local-path | grammar improved |
| 4 | `esr plugin feishu bind linyilun ou_xxx` | ✅ | ✅ | ✅ | **closed by PR #263 (plugin-scoped command registration rev-3)**: now `esr feishu bind <name> <ou_id>`; kind `feishu_bind`; cap `feishu/user-bind`; module `Esr.Plugins.Feishu.Commands.BindUser` | **fully closed** |
| 5 | `esr plugin install claude_code` | ✅ | ⚠️ | ⚠️ | same as #3; built-in by default | unchanged |
| 6 | `esr plugin claude_code set config http_proxy=…` | ✅ | ✅ | ✅ | **closed by Phase 7 + HR-2**: `/plugin:set` / `/plugin:show-config` / `/plugin:reload` | **fully closed** |
| 7 | (Feishu) `/help` `/doctor` | ✅ | ✅ | ✅ | works as designed | unchanged |
| 8 | (Feishu) `/session:new` | ✅ | ✅ | ✅ | **closed by Phase 6 colon-namespace cutover** | **fully closed** |
| 9 | (Feishu) `/workspace:add` | ⚠️ | ⚠️ | ⚠️ | workspace VS-Code redesign + colon-namespace narrowed gap; mental-model gap remains | partially closed |
| 10 | (Feishu) `/agent:add cc name=esr-developer` | ✅ | ✅ | ⚠️ | **closed functionally by M-2 + PR #248**: `/session:add-agent type=cc name=...` returns `actor_ids.cc/.pty` | **fully closed except minor wording** |
| 11 | (Feishu) plain text → reply with cwd | ✅ | ✅ | ✅ | working today | unchanged |
| 12 | (Feishu) `/agent:inspect esr-developer` → URL | ❌ | ❌ | ❌ | `/attach` removed by colon-namespace cutover; no slash returns the PtySocket URL | **regressed** |

**Net read (rev-4, post PR #263):** **10 of 12 fully closed** (was 7 fully + 2 partial in the 2026-05-06 audit, then 9 of 12 at rev-3). Three closes since rev-3: #4 plugin-scoped grammar (PR #263), #8 (Phase 6 colon cutover), #10 (M-2 + PR #248 multi-instance). Two structural / model-level gaps remain: #2 auto-admin, #9 mental-model partial. One regression sticks: #12 attach URL (now reframed under rev-4 grammar — see below).

The big architectural wins since 2026-05-06 — colon-namespace, plugin config, multi-instance per-session DynSup, atomic `add_instance_and_spawn`, M-3/M-4 legacy removal, session-first default resolution, plugin-scoped command registration — closed five steps. The rev-4 reframe (below) addresses #12 + the multi-instance helper gaps as one coherent grammar overhaul.

---

## Step-by-step delta from the 2026-05-06 audit

### Step 6 — `/plugin:set` shipped (Phase 7 + HR-2)

`Esr.Commands.Plugin.{Set, Unset, ShowConfig, ListConfig, Reload}` exist (`runtime/lib/esr/commands/plugin/`). Slash routes `/plugin:set`, `/plugin:show-config`, `/plugin:list-config`, `/plugin:unset`, `/plugin:reload` are wired. Three-layer config (manifest defaults / global / workspace overlay) and per-plugin manifest `hot_reloadable: true` opt-in landed via HR-1..HR-4. **Operator concern fully addressed.**

### Step 8 — Colon-namespace cutover (Phase 6)

`/session:new`, `/session:attach`, `/session:detach`, `/session:share`, `/session:add-agent`, `/session:set-primary`, `/session:remove-agent` all live in `runtime/priv/slash-routes.default.yaml`. The dash-separated forms (`/new-session` etc.) have been removed.

### Step 10 — Multi-instance agent spawn (M-2 + PR #248)

`/session:add-agent type=cc name=alice` goes through `Esr.Entity.Agent.InstanceRegistry.add_instance_and_spawn/2` (M-2.7) — atomic spawn under per-session `Esr.Scope.AgentSupervisor` (M-2.6) with `(CC, PTY) :one_for_all`. Response carries `actor_ids.cc` + `actor_ids.pty` UUID v4. Three sibling agents (alice/bob/carol) coexist without collision (verified by `tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh`).

### Step 12 — **Regression**: TUI URL access disappeared

The 2026-05-06 audit scored step 12 as I=⚠️, F=✅, G=❌ — `/attach` worked, just chat-scoped (not by name). After Phase 6 colon-namespace cutover, the standalone `/attach` slash was removed. `/session:attach` exists but: (a) requires UUID, (b) returns `{"attached": true}` only — **no URL**. `EsrWeb.PtySocket` still exists (`runtime/lib/esr_web/pty_socket.ex`) but no operator-facing slash surfaces a URL pointing at it.

**Concretely:** an operator using Feishu today has no way to get a clickable browser-TUI URL for any session. The web layer is shipped but unreachable from the operator surface.

---

## Cross-cutting gaps (re-scored)

### 1. Colon-namespace grammar — **CLOSED**

Phase 6 cutover landed; every operator slash now uses `<group>:<verb>`.

### 2. Operator-set per-plugin config — **CLOSED**

Phase 7 + HR-1..HR-4 shipped 3-layer config + `/plugin:set/unset/reload` + manifest `hot_reloadable` opt-in.

### 3. Mental-model alignment around `add` — **PARTIAL**

Workspace VS-Code redesign added `/workspace:add-folder`, `/workspace:use`, `/workspace:bind-chat`. The session direction still requires a pre-existing workspace before `/session:new` runs; there's no `/session:add-folder` that mutates the running session's workspace, and no `/session:new <NAME>` that lazy-creates a transient workspace under the hood.

`docs/notes/concepts.md`'s metamodel **is** session-first (Scope = runtime instance of a Session; workspace = Resource referenced by Scope). Implementation is workspace-first. Tracked as `docs/futures/todo.md` "Migrate to session-first model".

### 4. First-user-auto-admin — **STILL GAP**

`runtime/lib/esr/resource/capability/supervisor.ex:38-46` still requires `ESR_BOOTSTRAP_PRINCIPAL_ID` env var. The "first `user:add` becomes admin if no admin grant exists" path was never wired. ~30 LOC.

### 5. `esr.sh` references — **CLOSED**

Audit task 1 (per memory) replaced the stale references in `Esr.Commands.Doctor`.

---

### Session-first default resolution — **CLOSED 2026-05-08**

PR #263 implements the `2026-05-08-session-first-default-resolution.md` spec:
per-user default workspace replaces the system "default" workspace, `/user:add` auto-creates
`<username>-default`, new `/user:use` slash, and `/workspace:add-folder name=` falls back through
the same chain. Audit step 9's session-first 1-2-3 path (`/session:new` → `/workspace:add-folder` →
`/session:add-agent`) now works without ever typing a workspace name. Verified by e2e scenario 19.

### Plugin-scoped command registration — **CLOSED 2026-05-08 (rev-3)**

PR #263 also implements the `2026-05-08-plugin-command-registration.md` spec rev-3:
`Esr.Plugin.Manifest` gained a `slash_routes:` declaration block + 4 sub-validators
(slash prefix, kind prefix, permission cap subset, command_module loadability);
`Esr.Resource.SlashRoute.Registry` refactored to base + per-plugin overlay model with
hard collision detection; `Esr.Plugin.Loader.register_slash_routes/2` wired into
`start_plugin/2`. **Audit step #4** (`esr plugin feishu bind …` mental model) is now
implemented as `esr feishu bind …` — kind names renamed to comply with namespace
(`notify` → `feishu_notify`, `user_bind_feishu` → `feishu_bind`, `user_unbind_feishu`
→ `feishu_unbind`), caps renamed (`notify.send` → `feishu/notify-send`, new
`feishu/user-bind`). 3 commands physically migrated to `runtime/lib/esr/plugins/feishu/commands/`.
No back-compat for the old forms. Migration test asserts old kind names return `:not_found`.

## Newly-surfaced gaps (post multi-instance routing cleanup)

These are gaps introduced or exposed *by* the multi-instance work itself.

### A. `/session:list` + `/session:list-agents` — **MISSING**

`/session:attach`'s description literally says `"用 /session:list 查 UUID"` (`runtime/priv/slash-routes.default.yaml:309`), but `/session:list` is **not wired**. The same file at line 337 has a comment `# /session:end, /session:list, /session:bind-workspace, /session:info — deferred`.

`/agent:list` exists but lists **plugin-declared agent types** ("cc", etc.), not instances within a session. After M-2 enabled multi-instance per session, an operator with `cc:alice` + `cc:bob` + `cc:carol` in one session has no slash to enumerate them.

**Fix scope:** ~150 LOC across two `Esr.Commands.Session.{List,ListAgents}` modules + slash routes + e2e assertions. Highest leverage of any open item.

### B. `/session:attach name=<n>` + TUI URL returner — **MISSING**

`/session:attach` accepts only UUID. The pre-cutover `/attach` returned a clickable `EsrWeb.PtySocket` URL — that surface is gone post-Phase 6. Two coupled changes needed:

1. `Esr.Commands.Session.Attach` accepts `args.name` (resolves via NameIndex within the chat-scope's attached sessions).
2. The success result carries an `attach_url` field — backed by a one-shot signed token in PtySocket.

Without these, "click the link to open the agent's terminal" is structurally impossible for Feishu operators.

### C. Auxiliary multi-instance commands — **MISSING**

After M-2 made multi-instance routine:
- `/session:rename-agent name=<old> to=<new>` — not wired. Operators can't rename without remove + re-add (which loses state).
- `/session:show-primary` — only the setter exists (`/session:set-primary`); no read-only inspector.
- `/session:detach-agent` — `/session:detach` detaches the whole session from the chat; there's no per-agent detach.

These are small but visible holes once an operator starts using multi-instance.

### D. `@mention` routing not yet e2e-asserted

Both scenario 14 and scenario 18 deliberately skip the `@alice` / `@bob` routing assertion because the admin-submit harness can't inject inbound Feishu messages into the routing pipeline (`Esr.Entity.Agent.MentionParser` + `Esr.Entity.SlashHandler.resolve_routing/2` only fires on real inbound). Tracked as `e2e-14-routing` in `docs/futures/todo.md`. The runtime path is shipped and unit-tested; only the e2e gate is missing.

### E. PT-side ActorQuery resolution e2e gate — partial

`runtime/test/esr/integration/m5_actor_query_spawn_test.exs` (M-5.1) asserts `find_by_name` returns the CC pid post-spawn but skips the PT pid (PT lifecycle is bound to a real OS process, so its index registration races with the synchronous assertion). Scenario 18 covers it functionally but doesn't yet probe the live registry from the bash harness — depends on item B (TUI URL) to land first so the e2e can `curl` the attach URL and confirm aliveness.

---

## Recommended follow-ups (ordered by leverage)

| # | What | Estimated LOC | Notes |
|---|---|---:|---|
| 1 | `/session:list` + `/session:list-agents` | ~150 | Closes the `/session:attach` self-referential doc gap. Highest leverage. |
| 2 | First-user-auto-admin | ~30 | Single-file change in `Esr.Resource.Capability.Supervisor`. |
| 3 | `esr daemon init` + `esr daemon clear` | ~250 + ~700 | Folds 4 fresh-host setup steps into one command. Matches `tools/wipe-esrd-home.sh` direction in `docs/futures/todo.md`. |
| 4 | `/session:attach name=<n>` + TUI URL | ~300 | Restores the pre-Phase-6 attach UX with multi-instance support. |
| 5 | Session-first migration brainstorm + spec | spec-only | Tracked in `docs/futures/todo.md` as "Migrate to session-first model" — needs design before any LOC. |
| 6 | `/session:rename-agent`, `/session:show-primary`, `/session:detach-agent` | ~200 | Bundle of three small slashes that close audit Step 10 leftovers. |
| 7 | `@mention` routing e2e harness gap | ~100 | Either mock-feishu inbound injection OR a test-mode admin verb. Closes `e2e-14-routing` + improves scenario 18. |
| 8 | Plugin install-by-name (registry) | spec-only | Phase 2 of plugin spec. Deferred. Lower leverage than #1-#6. |

The first three (#1, #2, #3) cluster as "what an operator hits in their first 30 minutes". The next three (#4, #5, #6) cluster as "what the multi-instance work made possible but didn't quite finish". Items #7 and #8 are larger structural work.

---

## rev-4 — resource-typed grammar revision (2026-05-08)

After PR #263 landed, the user surfaced four architectural principles
that reframe gaps A/B/C above. The earlier proposals (`/session:list`,
`/session:rename-agent`, etc.) were partially mis-located — they put
operations on the *containing* resource's axis instead of the *operand*
resource's axis. This section documents the principles + the revised
plan.

### Principles

**P1 — Resource axis follows the OPERAND, not the container.**
A command operating on resource X belongs under `/<X>:<verb>`, even
if X lives inside another resource. Renaming an agent inside a
session is `/agent:rename`, not `/session:rename-agent`.

**P2 — Lists return their own resource, not their children.**
`/session:list` lists sessions. `/agent:list` lists agents. There is
no `/session:list-agents` — that's a category error.

**P3 — `attach` is a PTY operation, not a session operation.**
`attach` was originally for "give me the WebSocket URL to drive this
PTY". It belongs under `/pty:attach <pty_id>` (or `/pty:inspect`).
Other forms (e.g. "open the Claude Code TUI") are *shortcuts* that
internally resolve to a PTY id and call the same primitive. The
chat↔session relationship operations (today: `/session:attach`,
`/session:detach`) are about *binding*, not *terminal access* — they
should use a different verb. `bind-chat`/`unbind-chat` already
exists in the workspace namespace; a parallel session form would be
consistent.

**P4 — Operator command surfaces (slash + CLI + URI) need one
canonical reference doc.** Today only `/admin/slash_schema.json`
machine-readable; `/help` shows slashes only (omits internal_kinds);
URI grammar lives in a separate `docs/notes/esr-uri-grammar.md` with
no cross-link. An operator has no single place to discover the full
surface.

### Current grammar audit (against P1-P3)

| What it does | Today | Per P1-P3 |
|---|---|---|
| List session-internal agent instances (cc:alice, cc:bob, …) | nothing wired | `/agent:list` (chat-current session by default) |
| List agent **types** declared by enabled plugins | `/agent:list` (mis-named — it does this today) | `/plugin:agent-types` or `/agent-type:list` (frees `/agent:list` for instances) |
| List sessions in scope | nothing wired | `/session:list` |
| List PTY actors | nothing wired | `/pty:list` |
| Get TUI URL for an agent's terminal | nothing wired (orphaned `Esr.Commands.Attach`) | `/pty:attach pty=<id>` returning `attach_url`; `/cc:tui name=<n>` thin shortcut |
| Rename an agent instance | nothing wired | `/agent:rename name=old to=new` (NOT `/session:rename-agent`) |
| Set primary agent | `/session:set-primary name=<n>` | `/agent:set-primary name=<n>` |
| Show primary agent | nothing wired | `/agent:primary` (read-only) |
| Remove agent instance | `/session:remove-agent name=<n>` | `/agent:remove name=<n>` |
| Add agent instance | `/session:add-agent type=<t> name=<n>` | `/agent:add type=<t> name=<n>` (session implicit from chat) |
| Bind chat to session (transient/operational) | `/session:attach session=<uuid>` | `/session:bind-chat session=<uuid>` (mirrors `/workspace:bind-chat`) |
| Unbind chat from session | `/session:detach` | `/session:unbind-chat` |
| Switch chat-current session (multi-session per chat) | nothing wired | `/session:switch session=<uuid>` |
| End / destroy session | `internal_kind: session_end` (no slash) | `/session:end session=<uuid>` |
| List PTY processes | nothing wired | `/pty:list` |
| Send keys to PTY | `/pty:key key=…` | unchanged ✓ |

### Q&A — resolving the operator's 4 questions

**Q1. `/session:list` is for sessions; internals use `/<resource>:list`. Confirmed.**
- `/session:list` → list sessions in current scope (chat-bound or admin-scope).
- `/agent:list` → list agent instances in chat-current session (defaults to chat-current; explicit `session=<uuid>` arg for cross-session inspection).
- `/agent:list` today is mis-named (it lists *agent types* declared by enabled plugins). That semantic should move to `/plugin:agent-types` or `/agent-type:list`. Need to decide which.
- `/pty:list` → list PTY actors (chat-current session by default).

**Q2. `attach` returns a URL — under `/pty:*`, not `/session:*`. Confirmed.**
- `/pty:attach pty=<id>` → returns `attach_url` (signed token, one-shot — backed by `EsrWeb.PtySocket`).
- Could also expose `/pty:inspect pty=<id>` — alias OR variant returning richer state (env, cwd, history). Open question.
- `/cc:tui name=<agent>` → thin shortcut: looks up the agent's CC instance → resolves PTY actor id → calls `/pty:attach pty=<id>` semantics → returns the same URL. Future plugins can ship analogous shortcuts (`/voice:tui`, etc.).
- The current `/session:attach` (which does chat-binding, not URL emission) should rename — see Q3.

**Q3. Resource-typed verbs only.**
- All per-agent operations move from `/session:*` to `/agent:*`: rename, remove, add, set-primary, show-primary.
- `/session:attach` / `/session:detach` were always about chat-binding, not terminal access. Two options:
  - **A**: rename to `/session:bind-chat` / `/session:unbind-chat` for symmetry with `/workspace:bind-chat`.
  - **B**: drop entirely. Replace with `/session:switch session=<uuid>` (change chat-current) + `/session:end session=<uuid>` (destroy). The "multiple sessions attached to same chat" feature today is mostly unused — if it stays, A is the path; if not, B is cleaner.
  - *Recommend A*: keeps the multi-session-per-chat capability, makes the parallelism with `/workspace:bind-chat` explicit, drops the `attach` verb's URL-emission baggage.

**Q4. Unified command doc — does NOT exist.**
- Status today: `/admin/slash_schema.json` is the only machine-readable cross-section (slashes + internal_kinds). `/help` shows slashes only. URIs in a separate notes doc.
- Need: `docs/grammar/commands.md` (or similar) — auto-generated reference covering:
  - Slash commands (from slash-routes yaml + every plugin manifest's `slash_routes:` block)
  - CLI grammar (the `esr <head> <sub-actions>` synthesis from `cli/main.ex`)
  - HTTP/WebSocket URIs (from `EsrWeb.Router` + `EsrWeb.Endpoint`)
  - For each row: cap required, args schema, return shape, plugin source
- Generation: an `esr admin describe-grammar --format=markdown` command (or a mix task) that reads the same sources `/admin/slash_schema.json` does, plus `EsrWeb.Router.__routes__/0`, plus the plugin manifest files. ~200 LOC.

### Revised follow-up roadmap (supersedes the rev-3 list above)

| # | What | Spec needed? | LOC | Closes |
|---|---|:---:|:---:|---|
| 1 | Grammar spec for `/agent:*` + `/pty:*` + `/session:list` | yes (single spec) | spec | Foundation for #2-#5 |
| 2 | `/session:list` (sessions in scope) | covered by #1 | ~80 | rev-3 gap A (corrected) |
| 3 | `/agent:list` (instances; rename current → `/plugin:agent-types` or `/agent-type:list`) | covered by #1 | ~150 | rev-3 gap A (corrected) |
| 4 | `/pty:list` + `/pty:attach pty=<id>` (URL returner) | covered by #1 | ~250 | rev-3 gap B (relocated to /pty) + audit step #12 |
| 5 | `/cc:tui name=<n>` thin shortcut over `/pty:attach` | covered by #1 | ~50 | UX completeness |
| 6 | `/agent:rename` + `/agent:set-primary` + `/agent:primary` + `/agent:remove` + `/agent:add`; deprecate `/session:add-agent` etc. | covered by #1 | ~250 | rev-3 gap C (corrected) |
| 7 | `/session:bind-chat` + `/session:unbind-chat` + `/session:switch` + slash-wire `/session:end`; deprecate `/session:attach` + `/session:detach` | covered by #1 | ~200 | rev-3 conceptual gap |
| 8 | `docs/grammar/commands.md` generator (`esr admin describe-grammar --format=markdown`) | yes (small spec) | ~200 | rev-4 P4 |
| 9 | First-user-auto-admin (carried forward) | no | ~30 | rev-3 cross-cutting #4 |
| 10 | `esr daemon init` + `esr daemon clear` (carried forward) | no | ~250 + ~700 | first-30-min UX |

The grammar spec (#1) is the gate — once #1 is brainstormed and
approved, #2-#7 are purely mechanical implementation tasks (lots of
verbatim renames + a few new modules). #8 is independent and can run
in parallel.

---

## See also

- [`2026-05-06-bootstrap-flow-audit.md`](2026-05-06-bootstrap-flow-audit.md) — predecessor audit, 12-step baseline
- [`docs/futures/todo.md`](../futures/todo.md) — durable TODO; several items in this audit map to existing entries there
- [`docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md`](../superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md) — the spec whose landing today triggered this audit
- [`runtime/priv/slash-routes.default.yaml`](../../runtime/priv/slash-routes.default.yaml) — canonical slash command source
- [`tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh`](../../tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh) — multi-CC e2e gate landed alongside this audit
