# SessionTemplate + Channel

**Status:** Draft — pending user approval
**Date:** 2026-05-10
**Author:** Claude (with linyilun)
**Sister spec:** `2026-05-09-yaml-layout-v2-per-thing-directories.md` (storage layout — cross-cited)
**Replaces (in part):** `docs/issues/02-cc-mcp-decouple-from-claude.md` (the channel-abstraction half)

---

## 1. Why now

Three converging pressures:

1. **Multi-session-per-instance need** — operators want one CC instance to serve two
   different sessions (boss session + junior session, both seeing the same agent).
   Today an instance is bound to a single session_id; this scenario doesn't work.
2. **Second agent kind is coming** — codex / gemini-cli / voice plugin will all
   want their own agent type. Today's agent ↔ pipeline coupling lives across
   `agents.yaml` + several hard-coded paths in `Esr.Entity.FeishuChatProxy`
   + `Esr.Entity.SlashHandler` + `Esr.Entity.Agent.MentionParser`. Each new
   agent kind would re-walk every one of those couplings.
3. **`docs/issues/02-cc-mcp-decouple-from-claude.md` runtime portion still open** — PR #220
   (cc_mcp HTTP transport, 2026-05-05) addressed the immediate "cc_mcp dies with
   tmux" failure mode (tmux is gone now anyway, post PR-22), but the broader
   "channel as a first-class peer that any plugin can declare a dependency on"
   hasn't been addressed — the issue's own status reads "Brainstorm pending
   2026-05-01 / Decision: TBD" and was never updated. This spec subsumes that
   issue's runtime portion; when this spec lands, the issue doc itself needs a
   closing note. Today, claude_code's
   MCP HTTP transport, feishu's chat proxy, and any future codex transport
   all reinvent the same plumbing patterns.

These three pressures point at the same answer: **promote "how a session
is wired" out of plugin-private code into a declarative template, and
formalize the per-session communication peer as a first-class primitive**.

`docs/notes/concepts.md` rev-10 already names this pattern: a Session is
the **runtime instance** of a **Realm** (the kind of communication universe
the session lives in). This spec promotes the runtime half — `SessionTemplate`
+ `Channel` — into ESR. Realm stays a vocabulary concept in `concepts.md`
(no runtime presence; it's the umbrella that SessionTemplate + Channel
together implement).

---

## 2. Goals & non-goals

### Goals

- **`Esr.Channel` behaviour** — a per-session BEAM peer abstraction. Plugins
  ship Channel implementations (`Esr.Plugins.Feishu.Channels.ChatProxy`,
  `Esr.Plugins.ClaudeCode.Channels.McpHttp`). The behaviour standardizes
  start_link / send / subscribe + lifecycle.
- **`Esr.SessionTemplate`** — declarative yaml description of a session:
  which Channel kinds it composes, which Entities it spawns, how messages
  flow between them. Built-in templates ship in `runtime/priv/session_templates/`;
  operators can drop custom templates in `~/.esrd-<inst>/<inst>/session_templates/`.
- **Plugin manifest gains `channels:` + `agent_kinds:` blocks** — replaces
  today's `agents.yaml` (whose contents are conceptually plugin-owned anyway).
- **Drift prevention** — same pattern as the unified-command-grammar
  migration: the wiring lives in declarative yaml, validated at load time,
  CI gate prevents stale templates referencing missing channel kinds.
- **Multi-session-per-instance** — natural consequence of SessionTemplate:
  instances persist independently, sessions register interest in instances,
  channel routing carries session_id context.

### Non-goals

- **Realm as a runtime concept.** Realm stays vocabulary-only in
  `concepts.md`. SessionTemplate + Channel are the two concrete projections
  that plugin authors interact with.
- **Hot-reloadable templates for live sessions.** Editing a template at
  runtime affects only future sessions. Existing sessions keep the template
  they were created with (rewiring a live session would corrupt
  in-flight state).
- **Generic-stream Channel API.** No GenStage / Broadway. Channel is a
  GenServer-shaped peer with synchronous send + async subscribe. Backpressure
  isn't today's bottleneck.
- **Cross-instance Channel sharing.** Each Channel is per-session-instance.
  Two sessions sharing an agent share the agent (an `Instance{}`); they each
  have their own Channel set.

---

## 3. The three layers

ESR's runtime taxonomy already has Entity / Resource / Commands / Boundary /
Pipeline / OTP markers. SessionTemplate + Channel slot in like this:

| Layer | Concept | Today's analog | Lifecycle |
|-------|---------|----------------|-----------|
| **Agent type** | `cc` is which binary, what caps, what config_schema | `agents.yaml` | Plugin-declared, loaded at boot via plugin manifest |
| **SessionTemplate** | Which Channels + Entities + flow this session uses | Hard-coded across FeishuChatProxy / SlashHandler / agents.yaml's `pipeline:` | yaml-declared, validated at template load |
| **Channel** | Per-session transport peer (HTTP MCP, Feishu chat, etc) | Plugin-internal — each plugin reinvents | Plugin-shipped impl, supervised under per-session AgentSupervisor |
| **Agent instance** | `alice`, runtime UUID, actor_ids, session_ids | `Esr.Entity.Agent.InstanceRegistry` + (today) inline in `session.json` | Persisted in `sessions/<sid>/agents/<aid>.json` per yaml-v2 spec |

Realm is the vocabulary umbrella for "which combination of Channels +
Entities + flows constitutes a kind of session". A SessionTemplate IS the
declarative form of one Realm. Two Realms = two SessionTemplates.

---

## 4. Decisions (locked 2026-05-09 brainstorm)

| Q | Decision |
|---|----------|
| Naming | `Esr.Channel` (primitive) + `Esr.SessionTemplate` (composer); **drop** `Realm` as a code prefix; keep Realm in `concepts.md` as vocabulary umbrella. |
| A1 Channel behaviour | GenServer-shaped peer; `start_link/1`, `send/2`, `subscribe/3`, `config_schema/0` (optional callback for SessionTemplate validation). Supervised under per-session `Esr.Session.AgentSupervisor` (M-2.6 strategy: `:one_for_all`). |
| A2 Channel kind discovery | Plugins declare in manifest's `channels:` block; `Esr.Plugin.Loader` registers in `Esr.Channel.Registry` ETS. Channel referenced by `<plugin>.<channel_name>` in templates. |
| B1 Template file location | Built-in: `runtime/priv/session_templates/*.yaml`. Operator: `~/.esrd-<inst>/<inst>/session_templates/*.yaml`. Same-name override: operator wins (mirrors plugins.yaml 3-layer). |
| B2 Template yaml shape | `name + description + channels[] + agents[] + flow{inbound, outbound}`. `<runtime>` placeholder for parameters injected at session creation. |
| B3 Default template | A `default.yaml` in priv mirrors today's feishu-cc topology. `/session:new` without `template=` uses default. Operator can override default via `/plugin:set plugin=session key=default_template`. |
| C1 agents.yaml fate | Dissolves. Agent **type** definitions move into plugin manifest's `agent_kinds:` block. **Pipeline** (inbound/outbound chain) moves into SessionTemplate. **Instances** stay (per-session JSON, `agent_instance.v1.json` schema). |
| Storage | Agent instances split out of `session.json` into `sessions/<sid>/agents/<aid>.json` (one file per instance). **Implementation deferred to yaml-v2 spec PR**; this spec only declares the target shape and cross-cites yaml-v2. |
| D1 stop-gap | Dropped. The 80-LOC InstanceRegistry multi-session patch isn't done; the multi-session-per-instance case is a SessionTemplate acceptance test instead. |

---

## 5. Concrete shapes

### 5.1 `Esr.Channel` behaviour

```elixir
defmodule Esr.Channel do
  @moduledoc """
  Per-session transport peer abstraction. Each Channel impl is a
  GenServer-shaped module shipped by a plugin. Impls live under
  `Esr.Plugins.<plugin>.Channels.<name>`; behaviour requirements
  apply to every impl.

  Channels are supervised under per-session AgentSupervisor with
  `:one_for_all` strategy (M-2.6). Crash → siblings restart in
  lockstep → re-register their pids in the per-session Registry.
  """

  @callback start_link(opts :: keyword) :: {:ok, pid} | {:error, term}
  @callback dispatch(pid, msg :: term) :: :ok | {:error, term}
  @callback subscribe(pid, listener_pid, topic :: term) :: :ok
  @callback config_schema() :: map
  @optional_callbacks config_schema: 0
end
```

> Why `dispatch/2` not `send/2`: `Kernel.send/2` is auto-imported into every
> module. Naming the callback `send/2` forces every Channel impl that wants
> `Kernel.send/2` internally to write `Kernel.send/2` explicitly or
> `import Kernel, except: [send: 2]`. `dispatch` matches existing ESR
> vocabulary (FCP "dispatches" inbound) and avoids the shadow.

### 5.2 Channel kind discovery — plugin manifest

`runtime/lib/esr/plugins/<plugin>/manifest.yaml`:

```yaml
name: claude_code
version: 0.1.0
agent_kinds:
  - name: cc
    binary: claude
    exec_args: ["--mcp-config", "<mcp_config_path>"]
    capabilities_required: ["session:default/spawn"]
    config_schema:
      type: object
      properties:
        http_proxy: { type: string }
channels:
  - name: mcp_http              # plugin-local name
    module: Esr.Plugins.ClaudeCode.Channels.McpHttp
    config_schema:
      type: object
      properties:
        port: { type: integer }
slash_routes:                   # existing field, unchanged
  - "/claude_code:tui"
```

Loader walks every enabled plugin's manifest, populates two ETS tables:
- `:esr_channel_kinds` — `{<plugin>.<channel_name>, module}`
- `:esr_agent_kinds` — `{<plugin>.<kind_name>, definition}`

Templates reference `<plugin>.<name>`; loader rejects template loads that
reference missing kinds.

### 5.3 SessionTemplate yaml shape

`runtime/priv/session_templates/default.yaml`:

```yaml
schema_version: 1
name: default
description: Feishu chat → Claude Code agent (workspace-bound by default)

channels:
  - alias: in                   # template-local alias
    kind: feishu.chat_proxy     # <plugin>.<channel_name>
    config:
      app_id: <runtime>         # injected at session creation
      chat_id: <runtime>
  - alias: cc_mcp
    kind: claude_code.mcp_http
    config:
      port: ephemeral

agents:
  - kind: claude_code.cc        # <plugin>.<agent_kind>
    name: <runtime>             # operator-supplied
    consumes: [cc_mcp]          # which channel aliases this agent reads/writes

flow:
  inbound:
    - source: in.text
      pipeline:
        - Esr.Entity.Agent.MentionParser
        - <route_to_agent>      # built-in router; resolves agent name from
                                # mention or primary_agent
  outbound:
    - source: <agent>.reply
      sink: in.send
```

Validation rules at template load:
- Every `channel.kind` must resolve via `Esr.Channel.Registry`.
- Every `agent.kind` must resolve via `Esr.Plugin.Registry.agent_kinds`.
- Every `consumes` ref must match a `channels[].alias`.
- Every `flow` source/sink ref must match an alias or known router built-in.
- Reject duplicate aliases.

### 5.4 Default template + selection

- Initial install: priv `default.yaml` is copied to `~/.esrd-<inst>/<inst>/session_templates/`
  on first esrd boot if absent (mirrors plugin manifest seeding).
- `/session:new name=foo` (no `template=`) → uses default.
- `/session:new name=foo template=feishu-cc` → loads `feishu-cc.yaml`.
- Operator can change the default via `/plugin:set plugin=session key=default_template value=feishu-cc`.

### 5.5 Storage (cross-cited)

Per the locked decision, agent instances split into `sessions/<sid>/agents/<aid>.json`
(one file per instance, validated by `agent_instance.v1.json`). Implementation
of the storage migration lives in `2026-05-09-yaml-layout-v2-per-thing-directories.md`'s
PR (the user's parallel work). This spec assumes the new layout is in
place by the time SessionTemplate's session-creation path runs; if yaml-v2
hasn't merged when SessionTemplate Phase 5 is ready, SessionTemplate
either (a) waits, or (b) ships with a temporary inline-in-session.json
adapter that yaml-v2 later replaces.

---

## 6. Migration phases

The migration is multi-PR and ordered. Detailed task breakdown lives in
`docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md`.

| Phase | What | Touches |
|-------|------|---------|
| **1** | `Esr.Channel` behaviour + `Esr.Channel.Registry` ETS + tests | new modules; no existing module touched |
| **2** | First Channel impl: `Esr.Plugins.ClaudeCode.Channels.McpHttp` wraps the existing Elixir-side MCP HTTP transport (`EsrWeb.McpController` + `cc_mcp_ready` plumbing — already extracted from Python by PR-3.5) under the `Esr.Channel` behaviour. No new transport code; just the behaviour adapter. | claude_code plugin only |
| **3** | Second Channel impl: `Esr.Plugins.Feishu.Channels.ChatProxy` extracts the channel-shaped half (inbound dispatch + outbound reply emit) from the current `Esr.Entity.FeishuChatProxy`. Note: the file is at `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` but the **module namespace is still `Esr.Entity.FeishuChatProxy`** — Phase 3 either renames the module to align with the plugin path OR keeps the legacy namespace and only adds the Channel adapter alongside. Decide in plan. | feishu plugin only |
| **4** | `Esr.SessionTemplate` yaml schema + loader + Registry + validation + tests | new modules |
| **5** | `/session:new` consumes template; new sessions instantiate via SessionTemplate; `default.yaml` ships with feishu-cc topology | session creation path |
| **6** | Migration: existing sessions implicitly assigned `default` template; `agents.yaml` deleted; agent kind metadata moves to plugin manifest's `agent_kinds:`. **Non-trivial:** 13 current consumers in `runtime/lib/`, see §6.1 below for the per-consumer migration table. | cross-cutting cleanup |
| **7** | Multi-session-per-instance acceptance: same `Instance` registers in two sessions; reply routing uses incoming session context | `InstanceRegistry`, `CCProcess` |
| **8** | Docs + e2e scenario 24 (multi-session) + CI gate (template + manifest drift check) | docs, tests |

Phases 1-3 land independently (no behavioral change). Phase 4 is the
loader without consumers. Phase 5 is the cutover. Phases 6-8 are cleanup
+ acceptance.

### 6.1 agents.yaml dissolution — 13 consumers

`git grep -l agents.yaml runtime/lib/` (verified 2026-05-10) finds 13 files.
Phase 6 must address each:

| File | What it reads | Migration target |
|------|---------------|------------------|
| `application.ex` (4 functions including `extract_handler_modules/1`) | Boot-time Python sidecar discovery | Move to plugin manifest `agent_kinds[].handler_module` |
| `interface/spawner.ex` | Agent spawn entry | Read from plugin registry's `agent_kinds` |
| `interface/snapshot_registry.ex` | Snapshot of declared agents | Composes from plugin manifests |
| `entity/agent/registry.ex` | The agents.yaml ETS cache itself | **Deleted** (replaced by plugin agent_kinds registry) |
| `yaml/fragment_merger.ex` | Multi-layer yaml merge | Migrate semantics: today merges `core + plugin fragments + user override` for agents.yaml; post-Phase-6 the same merge story applies to `agent_kinds[]` across plugin manifests |
| `commands/workspace/remove.ex` | Workspace deletion checks for referencing agents | Read plugin agent_kinds + active instances |
| `commands/plugin/agent_types.ex` | `/plugin:agent-types` slash | Already reads from plugin registry post-PR-263; agents.yaml fallback removable |
| `resource/capability.ex` | Cap resolution from agent's `capabilities_required` | Migrate cap source from agents.yaml row to plugin manifest's `agent_kinds[].capabilities_required` (semantics preserved) |
| `commands/session/new.ex` | Default agent lookup at spawn | Same |
| `session/router.ex` | `:agents_yaml_reloaded` pubsub message | Rename / re-source from `:agent_kinds_reloaded` event when plugin manifest reloads |
| `session/agent_spawner.ex` | Spawn calls | Same as spawner |
| `claude_code/cc_process.ex` | `agents.yaml` reference in moduledoc only | doc edit only |
| `claude_code/manifest.yaml` | doc text reference | doc edit only |

Critical migrations: **`extract_handler_modules/1`** (Python sidecar
bootstrap) and **`Esr.Yaml.FragmentMerger`** (multi-layer merge) — both
need explicit Phase 6 sub-tasks. The plan PR breaks Phase 6 into
sub-phases per consumer.

---

## 7. What stays the same

- `Esr.Role.Control` / `Esr.Role.Pipeline` markers unchanged.
- `Esr.Session.AgentSupervisor` per-session DynSup unchanged (M-2.6 strategy
  applies to Channels too — they're children).
- `Esr.Entity.Agent.InstanceRegistry` keeps its ETS schema; `Instance.session_ids`
  becomes a list (was single `session_id`) but other fields unchanged. Phase 7.
- `slash-routes.default.yaml` (post unified-grammar) unchanged. New CI gate
  for templates is separate from the existing `mix esr.check_command_docs`
  gate.
- Plugin caps system unchanged. Channels inherit caps from the plugin.

---

## 8. What this enables next

- **New agent plugin (codex / gemini-cli / voice) zero-core-change.** Plugin
  drops a manifest with `agent_kinds:`, ships a Channel impl, ships a template;
  no edit to `Esr.Plugins.Feishu.*` or core dispatch code.
- **Per-flow Realm vocabulary now grounded.** Future docs talk about "the
  feishu-cc Realm" or "the http-codex Realm" with concrete SessionTemplate
  yaml backing the noun.
- **Replaceable transports.** A plugin can ship `mcp_http_v2` (e.g. with
  bidi streaming) alongside `mcp_http`; templates choose. No fork of CC.
- **Multi-session-per-instance** (Phase 7 acceptance case 1).
- **Multi-tenant patterns**: same template, multiple chat bindings, distinct
  instances per tenant — no plugin changes required.

---

## 9. Risks & open questions

### Risk: SessionTemplate ↔ yaml-v2 storage timing

If yaml-v2 (per-thing directory) layout hasn't shipped when SessionTemplate
Phase 5 lands, agent instances are still inline in session.json. Mitigation:
SessionTemplate Phase 5 ships a thin adapter that reads/writes either
shape; adapter deletes when yaml-v2 cleanup phase runs. The spec PRs for
yaml-v2 + SessionTemplate cross-cite each other; their plan PRs explicitly
sequence which lands first.

### Risk: Channel API ossifies on CC's quirks

Today only one agent kind exists. If we lock the Channel behaviour around
CC's MCP HTTP needs, the second agent (codex) might find the API ill-fitting.
Mitigation: Phase 4's SessionTemplate loader is the design partner — we
write the CC channel impl AND a stub codex/gemini channel impl in the
same Phase, validating the abstraction with two data points before Phase 5.

### Risk: Template drift vs deployed code

Operator-edited templates can reference deleted/renamed channel kinds or
agent kinds. Mitigation: `Esr.SessionTemplate.Registry` validates on load
and on plugin reload; any unresolvable ref fails the template load with
a clear error pointing at the missing manifest. Future: add a CI gate
analog to `mix esr.check_command_docs` that walks `runtime/priv/session_templates/`
+ all enabled plugin manifests and checks reference integrity.

### Risk: Hot-reload of templates breaks live sessions

Editing a template yaml at runtime — should existing sessions rewire? Per
the non-goals section: **no**. Live sessions keep the template they were
created with (frozen at session creation). Reload affects future sessions
only. Document this clearly so operators don't expect /plugin:reload to
re-route active conversations.

### Open question: Channel-scoped caps

Today's caps are session-scoped (`/session:default/...`). Should Channels
have their own cap scope (`/channels/feishu.chat_proxy/...`) so an operator
can grant "send to feishu chat" without granting "send to MCP"? Initial
recommendation: no. Keep session-scoped caps; channels inherit. Revisit
when a multi-tenant deployment surfaces a real cap-isolation gap.

### Open question: Cross-template imports

Should a template be able to `extends:` another template? Initial recommendation:
**no** for v1. YAGNI; templates are small. If 5+ templates duplicate the
same boilerplate, revisit.

### Open question: `agent_instance.v2` schema bump

Phase 7 changes `Instance.session_ids` from a single UUID string to a
list. `agent_instance.v1.json` requires `session_id` (singular) — bumping
to a list is a schema-version bump, not a v1 amendment. Phase 7 ships
`agent_instance.v2.json` + a one-shot migration that reads v1 files and
writes v2 (`session_ids: [old_session_id]`). No on-the-fly fallback in
the runtime; migration is a discrete one-pass step. Plan PR sequences
this with the yaml-v2 layout migration so they run together.

### Open question: `config_schema` parser reuse

The plugin manifest already has its own JSON-Schema-lite parser
(`Esr.Plugin.Manifest.parse_config_schema/1`, supports `string` +
`boolean`). The `Esr.Channel.config_schema/0` callback returns `map()`
— same dialect, or extended? Initial recommendation: same dialect,
reuse the parser; if Channel impls need richer types (integer, array,
ref) extend the parser once, not fork. Phase 4 finalizes.

### Open question: Placeholder grammar in templates

Three placeholder shapes appear in §5.3:
- `<runtime>` — value injected at session creation (e.g. `name`, `app_id`)
- `<route_to_agent>` — built-in router referenced by name
- `<agent>` — flow ref to "the agents declared in this template"

Phase 4 formalizes:
- `<runtime>` is a literal string-typed placeholder. Loader collects
  all `<runtime>` occurrences and exposes them as the template's
  parameter list to `/session:new`.
- `<route_to_agent>` is one of N built-in flow nodes registered in
  `Esr.Flow.NodeRegistry`. Plugins can ship more via manifest's
  `flow_nodes:` block.
- `<agent>` is a flow-language token resolving to "any agent declared
  in this template's `agents:` array".

### Open question: Cap inheritance during agents.yaml dissolve

Today `Esr.Resource.Capability` reads `capabilities_required` from
agents.yaml rows (line 63 of capability.ex). Phase 6 must move this
read to plugin manifest `agent_kinds[].capabilities_required` while
preserving cap-resolution semantics exactly. Add a Phase 6 sub-task:
"snapshot test against capabilities.yaml + a representative session
spawn before+after the cap source migration; assert resolved cap set
is identical."

### Open question: Built-in flow nodes

The example `flow.inbound[].pipeline:` references `Esr.Entity.Agent.MentionParser`
and `<route_to_agent>`. We need a small registry of "built-in flow nodes"
that templates can compose (mention parser, primary-agent router, etc).
Phase 4 enumerates these. Plugin authors can ship custom flow nodes too
via their manifest's `flow_nodes:` block (analog to `channels:`).

---

## 10. Acceptance criteria

The migration is "done" when:

- [ ] `Esr.Channel` behaviour exists and is implemented by at least 2 plugins
      (claude_code MCP HTTP + feishu chat proxy).
- [ ] `Esr.SessionTemplate` loader validates a template against
      `Esr.Channel.Registry` + `Esr.Plugin.Registry.agent_kinds` at load
      time; unresolvable refs fail loudly.
- [ ] `runtime/priv/session_templates/default.yaml` ships and reproduces
      today's feishu-cc behavior end-to-end (verified by e2e scenario 22 +
      a new scenario 24).
- [ ] `/session:new` consumes templates; default behavior unchanged
      (existing operators don't notice).
- [ ] Operator can drop `~/.esrd-<inst>/<inst>/session_templates/foo.yaml`
      and create sessions with `template=foo` without restarting esrd
      (template registry hot-reloads on `/plugin:reload`).
- [ ] **Multi-session-per-instance** (acceptance case 1): one Instance
      registered in two Sessions; reply routing uses incoming session's
      chat context. Verified by new e2e scenario 24.
- [ ] **agents.yaml deleted**; agent kind metadata lives in plugin manifests;
      pipeline lives in templates. `git grep -l agents.yaml runtime/lib/`
      returns zero hits (modulo migration cleanup notes in moduledocs).
      Phase 6's per-consumer sub-tasks (§6.1) all close.
- [ ] CI gate: a template referencing a missing channel kind fails CI.

---

## 11. References

- `docs/notes/concepts.md` rev-10 — Realm vocabulary
- `docs/issues/02-cc-mcp-decouple-from-claude.md` — Channel-abstraction half (this spec subsumes the runtime portion)
- `docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md` — sister spec (storage layout)
- `docs/superpowers/specs/2026-05-09-unified-command-grammar-and-errors.md` — same drift-prevention pattern, applied to commands rather than wiring
- `docs/superpowers/specs/2026-05-04-plugin-mechanism-design.md` — plugin manifest baseline this spec extends
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — current monolithic chat proxy (Phase 3 extracts the channel-shaped half)
- `runtime/lib/esr_web/mcp_controller.ex` — current MCP HTTP transport (Phase 2 extracts under Channel)
- `runtime/lib/esr/entity/agent/instance.ex` + `agent_instance.v1.json` schema — agent instance shape (Phase 7 extends `session_ids` to list)
- M-2.6 supervision strategy — Channels inherit `:one_for_all` per-session DynSup
