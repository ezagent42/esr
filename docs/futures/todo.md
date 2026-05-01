# ESR — durable TODO list

**Purpose**: persist work-in-flight + future-work items across CC sessions. Created 2026-04-29 because in-memory `TaskCreate`/`TaskList` is session-scoped and items got dropped between sessions.

**Owner**: this file is updated as part of any PR that:
- Defers a piece of work it could have done (mark as future)
- Discovers a new known issue (record + link)
- Closes a previously-tracked item (move to "Done — recent" or remove)

**Conventions**:
- One-line items with `[file:line](path)` or `[Spec §]` references when useful.
- "Status" column: `pending` / `in-flight` / `blocked` / `deferred`.
- `In flight` items name the PR / branch they live on.

---

## In flight (current PR)

(none — PR-21β shipped, see Done section below)

## Pending — concrete next PRs

| What | Tracked PR | Notes |
|---|---|---|
| Migrate `Esr.WorkerSupervisor` (adapter + handler) to `Esr.OSProcess` (erlexec) | done | PR-21β — `spawn_worker.sh` + pidfile + `cleanup_orphans` deleted; erlexec-managed DynamicSupervisor pattern; `ESR_SPAWN_TOKEN` Python guards. Net -230 LOC. See `docs/notes/erlexec-worker-lifecycle.md`. |
| Investigate: why E2E missed multi-adapter orphan duplication | pending | See task #222. Audit final_gate.sh + tests/e2e/ for assertions that would catch "1 user message → N replies" — likely none. May get folded into the lifecycle migration PR's testing chapter. |
| Spec: structured error/notification response system | pending design | Task #220. "error: unauthorized" 粒度不够; design ToolUseResponse/AssistantResponse-style envelope to compose 错误 + 操作建议. Brainstorm separately. |
| Spec: unify slash-command business logic into topology yaml | done | PR-21κ — `slash-routes.yaml` + `Esr.SlashRoutes` ETS registry + adapter-agnostic `SlashHandler.dispatch/3`. ~660 LOC of legacy bypass-list / per-command parsers / dispatcher dispatch tables deleted; yaml is the single source of truth for kind → permission + command_module + binding requirements. Editor-edit + watcher reload — no esrd restart needed. See `docs/notes/yaml-authoring-lessons.md` for the patterns. |
| `Esr.Peers.CapGuard` — extract Lane B from `Esr.PeerServer` | done | PR-21x #101. `deny_dm_last_emit` migrated; rate-limit globally consistent. |
| Cap principal_id rekey: caps stored under `linyilun` instead of `ou_*` post-bind | done | PR-21y #102. `bind-feishu` migrates existing `ou_xxx` caps + grants bootstrap under username. `unbind-feishu` revokes bootstrap when last binding goes. `cap grant ou_*` emits operator hint. PR-21s graceful resolve stays as backstop. |
| `describe_topology` filter for `users.yaml` | done | PR-21z #103. Allowlist hardened in `filter_workspace_for_describe/1` + 5 regression tests + `docs/notes/describe-topology-security.md`. |
| `AdapterChannelNewChainTest` known-flake formal entry | done | Now in `docs/operations/known-flakes.md`. |

## Pending — design discussions before PR

| What | Why deferred | Notes |
|---|---|---|
| Auto-bind feishu Option B/C (full automation with confirmation DM) | PR-21i shipped Option D (instructional DM only) | Original brainstorm in conversation 2026-04-29 ~02:00. User chose Option D for now. Revisit if instructional-DM friction is still too high after live use. |
| OAuth-based esr user registration | Spec §"Out of scope" | Manual `esr user add` for now. Real OAuth needs Feishu Open Platform integration. |
| Deprecate `cc_tmux` Python adapter | PR-21e mentioned as "out of scope" | `cc_mcp + TmuxProcess` is the new path. cc_tmux still referenced by `worker_supervisor.ex:46` + tests. Cleanup PR if it's truly dead. |
| `tag=` alias removal in slash parser (D14) | done | PR-21α #104. Removed in slash parser; `final_gate.sh` `--param tag=` is `cmd run` template layer, untouched. |
| **Yaml-ify adapter sidecar dispatch** (`@sidecar_dispatch`) | Workshop 2 | After Workshop 1 (slash routing) ships. `worker_supervisor.ex:45` map. Adding new adapter type today touches Elixir. |
| **Yaml-ify permissions registry** | Workshop 2 | Centralize the `permissions/0` callbacks scattered across `Esr.Admin`, `Esr.PeerServer`, future handlers. Single `permissions.yaml` listing perms + scope prefixes (would have prevented PR-21γ's `validate_scope` bug). |
| **Yaml-ify default values** (agent="cc", role="dev", start_cmd, kill_timeout) | Workshop 3 | `defaults.yaml`. Currently scattered across 5+ modules; tests + dev quirks suffer from no central spec. |
| **Yaml-ify rate-limit windows** (`@deny_dm_interval_ms`, `@guide_dm_interval_ms`) | Workshop 3 | Operator-tunable. Dev / prod / e2e want different values. |
| **Externalize doctor / help text to markdown** | Edge / cosmetic | Long Chinese heredoc strings in `feishu_app_adapter.ex`. Not strictly yaml-able (multi-line markdown is friendlier than yaml). Operator wants to tweak phrasing without restart. |
| **Per-workspace worktree path convention** | Speculative | Today PR-21θ hardcodes `<root>/.worktrees/<branch>`. Workspace yaml could carry `worktree_pattern:` to override (e.g. `<root>-<branch>` sibling-dir). |
| **Yaml file visualization / pretty-print** | New 2026-04-30 | Today operators `cat ~/.esrd/<env>/workspaces.yaml` etc. to inspect runtime state. After PR-21κ ships, the yaml surface grows: `slash-routes.yaml` + `workspaces.yaml` + `users.yaml` + `capabilities.yaml` + `agents.yaml` + `adapters.yaml` — cross-references hard to follow. Candidates: (a) `/topology` slash that renders all the connections, (b) `esr show` CLI that pretty-prints with cross-refs, (c) mermaid/graphviz diagrams generated at boot, (d) web view via Phoenix LiveView. Brainstorm + scope decision needed before implementation. |
| **Auto-create session: meaningful default cwd** | New 2026-05-01 | When a chat with no live session receives non-slash text, FAA broadcasts `:new_chat_thread` and SessionRouter auto-creates a session with `dir="/tmp"` (TmuxProcess default). `/tmp` has no git context and isn't user-meaningful. User suggestion 2026-05-01: use `$ESRD_HOME/<env>/<workspace>/sessions/<sid>/` so ESR self-manages the path; resumable across restarts; doesn't pollute user's git repos. Tradeoff: claude has no git context there → can't write code easily. Alternatives: (b) require operator to /new-session first (disable auto-create), or (c) thread workspace.default_root through workspaces.yaml. Brainstorm before implementing — the right answer depends on whether auto-create is a core UX or a backstop. PR-21τ added a safety net: esr-cc.sh now falls back to `pwd` instead of hard-failing. |
| **Spec: agent (cc) startup config first-class** | New 2026-05-01 | Today CC's startup is a stack of moving parts: agents.yaml's `cc` entry, workspaces.yaml's `start_cmd`, scripts/esr-cc.sh, scripts/esr-cc.local.sh (gitignored, proxy/secrets), launchd plist EnvironmentVariables, claude's own `~/.claude/` cached creds. An operator-on-a-fresh-host hitting `Please run /login - 403` has no single doc / health check that points to the right config layer. User ask 2026-05-01: CC is one of ESR's agents — its config preconditions should be **explicit and validated**, not implicit-via-shell-script. Candidates: (a) agents.yaml gains a `preconditions:` block (`http_proxy: required\|optional`, `anthropic_api_auth: required`, etc.) and a startup-time validator that fails fast with a clear message; (b) `/doctor` agent-aware — checks Anthropic API reachability + cred validity per agent; (c) deploy doc enumerates the layers + which goes where. Brainstorm needed: how much of "agent prerequisite" belongs in code vs documented runbook. Triggered by tonight's PR-21κ live-test where 4+ layers had to be debugged (PR-21σ ESRD_HOME, PR-21τ pwd fallback, esr-cc.local.sh proxy, claude /login). |
| **Reliability: tmux-death zombie session** | New 2026-05-01 | When the tmux server backing a session dies (manual `kill-session`, claude crash, host reboot), `TmuxProcess.on_terminate` fires but the rest of the session pipeline (cc_process, FCP, SessionRegistry) doesn't notice. Next inbound for the same `(chat_id, app_id, thread_id)` looks up the still-registered session and routes the channel notification into a dead path — claude isn't there to receive. Discovered 2026-05-01 during PR-21κ live-test: had to `launchctl kickstart -k esrd-dev` to clear it. Likely fix: TmuxProcess termination should cascade — either supervisor strategy `:one_for_all` (full session teardown so re-routing auto-creates fresh) or explicit `SessionRegistry.unregister_session/1` in TmuxProcess's terminate. Related to task #222 (E2E missed multi-adapter orphan). Brainstorm before implementing — `:one_for_all` is heavy; might prefer surgical unregister. |
| **Re-implement PR-21ψ rewire (deadlock-safe)** | New 2026-05-01 | PR-21ψ tried to fix tmux-death zombie via `TmuxProcess.init/1` calling `DynamicSupervisor.which_children(peers_sup)` to find siblings + `:sys.replace_state` patch their `:tmux_process` neighbor. **Deadlocked at very first session spawn:** `which_children` is `GenServer.call(peers_sup, ..., :infinity)` but `peers_sup` is busy synchronously waiting for THIS init to return (DynamicSupervisor processes `start_child` linearly). Reverted in dev. To re-enable the rewire UX safely: schedule via `Process.send_after(self(), :rewire_siblings, 50)` in init so the rewire runs AFTER init returns and peers_sup is free; OR have a separate per-session "wirer" GenServer that watches all peer pids via `Process.monitor` and rewires on DOWN. |
| **BEAM lesson note: supervisor reentrancy in child init** | New 2026-05-01 | Tonight's PR-21ψ deadlock taught: **never call back into your own supervisor (or its children) from within a child's `init/1`**. `DynamicSupervisor.start_child` is synchronous — the supervisor's GenServer is blocked inside `handle_call({:start_child, …})` waiting for the spawned child's `:proc_lib.start_link` to ack init. If init makes ANY `GenServer.call` to that supervisor (`which_children`, `count_children`, `terminate_child`, …), the call cycles back into the same mailbox → infinite wait (these supervisor calls default to `:infinity` timeout, so they NEVER return). Escape hatches: (a) defer via `Process.send_after(self(), :do_thing, ms)` — runs after init returns; (b) `{:ok, state, {:continue, :step}}` in init's return — same effect cleaner; (c) move logic to a separate process that owns the cross-talk. Worth adding to `docs/notes/erlexec-worker-lifecycle.md` or new `docs/notes/beam-init-reentrancy.md` so this doesn't repeat. |
| **cc_mcp decouple + abstract "channel" concept** | New 2026-05-01 — deferred until **after** PR-22 (xterm.js / PtyProcess) lands | Two intertwined problems surfaced 2026-05-01: (1) cc_mcp is parented by claude → tmux → dies when tmux dies, taking its `cli:channel/<sid>` PubSub subscription with it; (2) "channel" (the cc_mcp ↔ esrd notification pipe) is hand-rolled per-agent — when we add a 2nd agent type (codex, gemini-cli, custom), we'll re-implement the same WebSocket-subscribe-PubSub pattern. **User direction**: abstract `channel` as a first-class peer/concept so future agents reuse it. Per-session dedicated channel actor (1:1 with agent) — supervised by BEAM independent of tmux/claude lifecycle. claude reaches it via HTTP MCP transport (port allocated by BEAM, exported via env). Open issue: `docs/issues/02-cc-mcp-decouple-from-claude.md`. Discuss after xterm.js refactor (PR-22) is shipped, since PtyProcess changes the parenting model and may simplify the channel actor's spawn shape. |
| **Multi-session-per-chat routing: thread_id binds incorrectly** | New 2026-05-01 — discovered during PR-22 live test | Reproduced 2026-05-01: user creates `/new-session test-pr-22-v2` → sid `2GUF...`. Sends `hi` → claude (`DQKG...` from earlier) replies. `/attach` returns `DQKG...` URL. Root cause: `SessionRegistry.register_session` ETS key is `(chat_id, app_id, thread_id)` and Feishu assigns each user message its own `thread_id` (the message_id, not the chat root). So each `/new-session` registers under that slash-message's thread_id, while subsequent inbound text uses a different thread_id and routes to whichever session was registered there. Result: new sessions get orphaned; chat keeps talking to the prior one. PR-22's `/attach` is correct (returns the session messages actually route to), but the higher-level UX is broken. Fix candidates: (a) `/new-session` always registers under a synthetic "current" thread_id (e.g. just chat_id) so it overwrites; (b) `/switch-session name=<n>` slash to explicitly rebind; (c) chat-binding becomes (chat_id, app_id) only, drop thread_id from the routing key (but breaks Feishu-thread isolation if/when threads matter). Brainstorm + spec needed before implementing — touches the actor-routing topology spec. Related: D8 uniqueness (sid global + name in workspace) doesn't enforce 1-active-session-per-chat — would need a 4th uniqueness layer or explicit "current" pointer. |
| **Browser attach UX: xterm.js flashing under LiveView** | New 2026-05-01 — discovered during PR-22 live test | Operator reports: terminal flashes constantly even with `phx-update="ignore"` + `requestAnimationFrame`-deferred fit + ttyd-style theme (PR #142). Suspected causes: (a) LiveView WS heartbeat/reconnect cycles patching parent DOM despite the ignore flag; (b) Claude TUI emits frequent ANSI clear+redraw; (c) `cursorBlink: true` reads as flashing on slow CPUs. Mature alternative: `ttyd` (C, ~1.5k stars) — separate web-terminal server, browser → ttyd → bash → claude, completely bypasses BEAM's stdout fan-out. **But ttyd alone has no persistence** (each page-reopen = new PTY); needs ttyd + dtach to survive page closes. **Better path**: keep BEAM's PtyProcess (it's already the persistence layer — laptop close/open = reconnect to same PTY in BEAM), drop only the LiveView wrapper, replace with raw Phoenix.Channel + xterm.js. Channel doesn't do DOM diffing; flashing should die. ~80 LOC delete (LiveView + layout + browser pipeline) + ~50 LOC add (Phoenix.Channel module + adjusted xterm hook). Dig DevTools first (option a) to confirm root cause is LiveView before doing the refactor. |

## Pending — observability / ops

| What | Notes |
|---|---|
| `ChannelClient` align with phx-py reference | `docs/futures/channel-client-phx-py-alignment.md` — full audit of self-hosted Phoenix client vs phx-py best practices. PR-21l fixed heartbeat; per-call timeout + connection-state events still missing. |
| ExDoc-based runtime API docs | Currently `gen-docs.sh` only covers click CLI + `cli_channel.ex` dispatch topics. Other internal modules have no auto-docs. |
| Per-session role override | Workspace dictates `role:` today; per-session override mentioned in spec out-of-scope. |
| Cross-workspace branch sharing | Speculative; spec out-of-scope. |
| Worktree GC sweep | Periodic prune of branchless worktrees. Operator runs `git worktree prune` manually for now. |

## Done — recent (last ~10 PRs, for context)

Track only PR-21 series + immediate context. Older PRs are in git log.

- PR-20 `#75` 2026-04-29 — docs/notes/esr-uri-grammar.md surfaced
- PR-21a `#76` — `Esr.Users` + `users.yaml` + `esr user *` CLI
- PR-21b `#77` — `Esr.Uri` `:org` kwarg + `Topology.user_uri` rekey
- PR-21c `#78` — workspace yaml schema (drop `cwd`, add `owner`+`root`) → see PR-22 reversal
- PR-21d `#79` — `/new-session` grammar unified + `Esr.Worktree` module
- PR-21e `#80` — `EsrWeb.PendingActions` + cc_tmux per-env tmux socket
- PR-21f `#81` — wire PendingActions into `feishu_app_adapter`
- PR-21g `#82` — SessionRegistry D8 uniqueness + `/end-session` resolver
- PR-21h `#83` — `final_gate.sh` `tag=` → `name=` sweep
- PR-21i `#84` — unbound-user-guide DM
- PR-21j `#85` — `/sessions` + `/workspace info`/`sessions`
- PR-21k `#86` — `/new-workspace` slash + chat-guide DM update
- PR-21l `#87` — `ChannelClient` Phoenix heartbeat (critical bug fix)
- PR-21m `#96` — orphan subprocess cleanup at boot + `esr daemon doctor`
- PR-21n `#95` — `esr daemon {start,stop,restart,status}` CLI
- PR-21o `#93` — subprocess file logging defaults to DEBUG
- PR-21p `#88` — `docs/futures/channel-client-phx-py-alignment.md`
- PR-21q `#90` — bootstrap slash bypass + auto-grant caps on bind-feishu
- PR-21r `#91` — split `/help` (command reference) from `/doctor` (status diagnostic)
- PR-21s `#92` — cap rekey to esr-username + `unbind-feishu` auto-revoke + flat-cap matcher fix
- PR-21t `#94` — chat-guide DM stale-text fix + `/new-workspace` bypass route
- PR-21u `#97` — `docs/notes/actor-role-vocabulary.md` (canonical taxonomy)
- PR-21v `#98` — `Esr.Role.*` compile-time category markers + vocab restructure
- PR-21w-tracker `#99` — `docs/futures/todo.md` durable task tracker + `AdapterChannelNewChainTest` flake entry
- PR-21w `#100` — `*Guard` extractions: `EsrWeb.PendingActions` → `PendingActionsGuard`, `Esr.Peers.UnboundChatGuard`, `Esr.Peers.UnboundUserGuard`
- PR-21x `#101` — `Esr.Peers.CapGuard` extracted from `Esr.PeerServer` Lane B + FAA deny-DM rate limit
- PR-21y `#102` — Cap principal_id rekey to esr-username (bind-feishu migrates existing `ou_*` caps + grants bootstrap under username)
- PR-21z `#103` — `describe_topology` users.yaml security audit + regression tests + `docs/notes/describe-topology-security.md`
- PR-21α `#104` — remove `tag=` alias from slash parser (`/new-session`)
- PR-21β `#105` 2026-04-30 — `Esr.WorkerSupervisor` migrated to erlexec; deletes pidfile/cleanup_orphans/spawn_worker.sh; adds `ESR_SPAWN_TOKEN` guard
- PR-21γ `#106` 2026-04-30 — `validate_scope` accepts `session:` prefix + full-cap fallback; fixes prod `unauthorized` for `linyilun` despite `*`. Discovered while debugging the orphan-adapter follow-up.
- PR-22 `#89` — remove `workspace.root`, repo becomes per-session
- PR-21δ `#108` 2026-04-30 — `resolve_username` lookup chain matches real adapter envelope (principal_id + payload.args.sender_id); `/new-workspace` no longer rejects with `invalid_args`
- PR-21ε `#110` 2026-04-30 — slash-handler reads `chat_id`/`thread_id` from real adapter envelope shape (`payload.args.X` fallback for `payload.X`)
- PR-21ζ `#112` 2026-04-30 — git flow `dev → main` enforcement: `enforce-pr-from-dev.yml` GHA + `scripts/promote-dev-to-main.sh` + `docs/dev-flow.md`
- PR-21η `#113` 2026-04-30 — `Workspace.New` idempotent (re-runs on already-bound chats append vs reject)
- PR-21θ `#114` 2026-04-30 — derive cwd from `<root>/.worktrees/<branch>` (Convention B); cwd= removed from slash grammar
- PR-21κ Phase 1-6 (this PR) — yaml-driven slash routing: `slash-routes.yaml` + `Esr.SlashRoutes` registry + `SlashHandler.dispatch/3`; deletes `inline_bootstrap_slash?` quartet, `parse_command/1` per-command parsers, Dispatcher's `@required_permissions` + `@command_modules` constants. Adapter-agnostic. ~660 LOC net deletion.
