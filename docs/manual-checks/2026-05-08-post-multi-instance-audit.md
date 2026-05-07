# Post multi-instance routing audit — 2026-05-08

**Operator-proposed journey** (12 steps, original from 2026-05-06 rev-3) vs **shipped surface** as of `origin/dev` `a69fd6a` (multi-instance routing cleanup PR #261 just landed).

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
| 4 | `esr plugin feishu bind linyilun ou_xxx` | ✅ | ✅ | ❌ | bind is `esr user:bind-feishu`, plugin-scoped form still missing | unchanged |
| 5 | `esr plugin install claude_code` | ✅ | ⚠️ | ⚠️ | same as #3; built-in by default | unchanged |
| 6 | `esr plugin claude_code set config http_proxy=…` | ✅ | ✅ | ✅ | **closed by Phase 7 + HR-2**: `/plugin:set` / `/plugin:show-config` / `/plugin:reload` | **fully closed** |
| 7 | (Feishu) `/help` `/doctor` | ✅ | ✅ | ✅ | works as designed | unchanged |
| 8 | (Feishu) `/session:new` | ✅ | ✅ | ✅ | **closed by Phase 6 colon-namespace cutover** | **fully closed** |
| 9 | (Feishu) `/workspace:add` | ⚠️ | ⚠️ | ⚠️ | workspace VS-Code redesign + colon-namespace narrowed gap; mental-model gap remains | partially closed |
| 10 | (Feishu) `/agent:add cc name=esr-developer` | ✅ | ✅ | ⚠️ | **closed functionally by M-2 + PR #248**: `/session:add-agent type=cc name=...` returns `actor_ids.cc/.pty` | **fully closed except minor wording** |
| 11 | (Feishu) plain text → reply with cwd | ✅ | ✅ | ✅ | working today | unchanged |
| 12 | (Feishu) `/agent:inspect esr-developer` → URL | ❌ | ❌ | ❌ | `/attach` removed by colon-namespace cutover; no slash returns the PtySocket URL | **regressed** |

**Net read:** **9 of 12 fully closed** (was 7 fully + 2 partial in the 2026-05-06 audit). Two improvements (#6, #8, #10), one regression (#12 — the previous `/attach` was working but is now silently gone), three structural / model-level gaps remain (#2 auto-admin, #4 plugin-scoped grammar, #9 mental-model).

The big architectural wins since 2026-05-06 — colon-namespace, plugin config, multi-instance per-session DynSup, atomic `add_instance_and_spawn`, M-3/M-4 legacy removal — closed three steps and improved two more, but **surfaced one previously-shipped operator entry point getting deleted in the colon cutover** (#12 attach URL).

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

## See also

- [`2026-05-06-bootstrap-flow-audit.md`](2026-05-06-bootstrap-flow-audit.md) — predecessor audit, 12-step baseline
- [`docs/futures/todo.md`](../futures/todo.md) — durable TODO; several items in this audit map to existing entries there
- [`docs/superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md`](../superpowers/specs/2026-05-07-multi-instance-routing-cleanup.md) — the spec whose landing today triggered this audit
- [`runtime/priv/slash-routes.default.yaml`](../../runtime/priv/slash-routes.default.yaml) — canonical slash command source
- [`tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh`](../../tests/e2e/scenarios/18_multi_cc_atomic_spawn.sh) — multi-CC e2e gate landed alongside this audit
