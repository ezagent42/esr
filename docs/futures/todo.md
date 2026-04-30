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
| Spec: unify slash-command business logic into topology yaml | pending design | Task #221. Move slash routing from Elixir code into yaml so future changes don't need esrd restart. Brainstorm separately. |
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
