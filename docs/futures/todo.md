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

(none — PR-21w shipped)

## Pending — concrete next PRs

| What | Tracked PR | Notes |
|---|---|---|
| `Esr.Peers.CapGuard` — extract Lane B from `Esr.PeerServer` | done | PR-21x #101. `deny_dm_last_emit` migrated; rate-limit globally consistent. |
| Cap principal_id rekey: caps stored under `linyilun` instead of `ou_*` post-bind | PR-21y | Currently PR-21s does **graceful resolution** at check time (open_id → username). Storing under username would require migrating capabilities.yaml + all envelope construction sites. |
| `describe_topology` filter for `users.yaml` | PR-21z | Spec §"Out of scope". feishu_ids are sensitive — should NOT be exposed via the MCP `describe_topology` tool. Default-deny. See `docs/superpowers/specs/2026-04-28-session-cwd-worktree-redesign.md` §"Out of scope". |
| `AdapterChannelNewChainTest` known-flake formal entry | done | Now in `docs/operations/known-flakes.md`. |

## Pending — design discussions before PR

| What | Why deferred | Notes |
|---|---|---|
| Auto-bind feishu Option B/C (full automation with confirmation DM) | PR-21i shipped Option D (instructional DM only) | Original brainstorm in conversation 2026-04-29 ~02:00. User chose Option D for now. Revisit if instructional-DM friction is still too high after live use. |
| OAuth-based esr user registration | Spec §"Out of scope" | Manual `esr user add` for now. Real OAuth needs Feishu Open Platform integration. |
| Deprecate `cc_tmux` Python adapter | PR-21e mentioned as "out of scope" | `cc_mcp + TmuxProcess` is the new path. cc_tmux still referenced by `worker_supervisor.ex:46` + tests. Cleanup PR if it's truly dead. |
| `tag=` alias removal in slash parser (D14) | PR-21d kept it as rollout-friendly alias | After all real callers migrate to `name=`, drop the alias. Currently still used by `final_gate.sh` `--param` tags (different layer; not slash). Verify before removal. |

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
- PR-22 `#89` — remove `workspace.root`, repo becomes per-session
