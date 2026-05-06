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

(none)

## Pending — Plugin work multi-Phase plan (2026-05-05 brainstorm)

PR-180 series (today) = **Phase 1**: Loader + Manifest + 3 stub manifests + integration tests + RCA helpers + scenario-07 grep fix + in-process auto-confirm + tools/esr-debug.

| Phase | Spec | What | Notes |
|---|---|---|---|
| **Phase 1** — plugin loader foundation | `docs/superpowers/specs/2026-05-04-core-decoupling-design.md` (Spec A) + `2026-05-04-plugin-manifest-design.md` (Spec B) | Loader + Manifest + stub manifests + Loader.run_startup/0 + StatefulRegistry runtime API. | ✅ done — PRs #180–#187, #213, #219. |
| **Phase 2** — slash/CLI/REPL/admin unification | `docs/superpowers/specs/2026-05-05-slash-cli-repl-elixir-native.md` | Single dispatch path: delete Admin.Dispatcher, rewrite Python CLI as Elixir-native escript (`runtime/esr`), schema-driven CLI/autocomplete, voice plugin deletion. | ✅ **mostly shipped** — PRs #193 (voice deletion), #194–#202 (escript skeleton + ReplyTarget + Slash.* extraction + Esr.Admin.Dispatcher deletion), #211–#216 (slash routes for actors/cap/users), #222 (cli-channel→slash), #223 (Python CLI deletion). Net delete ~10–12k LOC vs original "~2500" estimate. **REPL still pending** (deferred to a follow-up — `esr exec /<slash>` is the current interactive surface). |
| **Phase 3** — plugin physical migration | `docs/superpowers/specs/2026-05-05-plugin-physical-migration.md` | Move feishu + claude_code modules from core into `runtime/lib/esr/plugins/<name>/`. Decouple cc agent_def from feishu. | ✅ shipped — PRs #203 (drop fallback Sidecar), #204 (StatefulRegistry), #205 (feishu move), #206 (cc move), #207 (cc no longer mentions "feishu"), #209 (drop permissions_registry.json), #219 (PR-3.4 feishu startup hook), #220 (PR-3.5 cc_mcp HTTP transport). |
| **Phase 4** — cleanup | (no formal spec — covered by per-PR field notes) | Stub manifest deletion (kept until Phase 3 done — they're now real plugins), legacy bash + websocat helpers, `Esr.Admin.*` namespace, `permissions_registry.json` JSON dump. | ✅ **mostly shipped** — PR-4.3 collapsed `Esr.Admin.{Supervisor,CommandQueue.*}` → `Esr.Slash.*` (#208); PR-4.4 dropped permissions_registry.json (#209); PR-22 deleted TmuxProcess + cc_tmux adapter (#163, #157). Stub manifests are now real plugin modules — no further deletion needed. |

## Pending — concrete next PRs

| What | Tracked PR | Notes |
|---|---|---|
| Investigate: why E2E missed multi-adapter orphan duplication | pending | See task #222 (in-memory tracker). Audit final_gate.sh + tests/e2e/ for assertions that would catch "1 user message → N replies" — likely none. May get folded into the lifecycle migration PR's testing chapter. |
| Spec: structured error/notification response system | pending design | Task #220. "error: unauthorized" 粒度不够; design ToolUseResponse/AssistantResponse-style envelope to compose 错误 + 操作建议. Brainstorm separately. |
| Channel abstraction (per-session BEAM-supervised peer) | pending design | Spawned during 2026-05-01 cc_mcp brainstorm + addressed *partially* by PR-3.5 (cc_mcp HTTP transport). The full abstraction — channel as a first-class peer, decoupled from claude/PtyProcess lifecycle, reusable for codex/gemini-cli/custom agents — is still future work. Open issue: `docs/issues/02-cc-mcp-decouple-from-claude.md`. |
| `esr scenario run` port + Python SDK trim | deferred from PR-223 | Python click CLI is gone (PR-223), but `py/src/esr/` still has the SDK (`adapter.py`, `handler.py`, `events.py`, `actions.py`, `ipc/handler_worker.py`) used by adapters/feishu/ + handler sidecars. The yaml-driven `esr scenario run` was deleted with the CLI — its functional replacement is `tests/e2e/scenarios/0X_*.sh` + `make e2e-N`. No port needed. SDK stays as long as Python adapter sidecars exist. |
| `esr daemon init` + esrd home redesign | deferred — **unblocked: workspace redesign decision made (spec 2026-05-06, shipped after merge of feature/workspace-vs-code-redesign-impl)** | Add `esr daemon init [--force] --admin <user> --plugins <list>` so a fresh deploy is a one-command bootstrap. Re-architect esrd home so binary-managed yaml (slash-routes, agents) re-copies from priv at every boot (preventing the schema-drift bug that broke `/help` after PR-198 renamed `Esr.Admin.Commands.*` → `Esr.Commands.*`). All yaml becomes CLI-managed, never hand-edited; init seeds operator-authored stubs (capabilities, users, workspaces, adapters, plugins) from CLI params. Estimated ~700-1000 LOC across init command + gap-filling slash commands. Workspace concept is retained (VS-Code-style hybrid storage); the 14 new `/workspace*` slashes are already landed — `esr daemon init` can build on them directly. |

## Pending — design discussions before PR

| What | Why deferred | Notes |
|---|---|---|
| Auto-bind feishu Option B/C (full automation with confirmation DM) | PR-21i shipped Option D (instructional DM only) | Original brainstorm in conversation 2026-04-29 ~02:00. User chose Option D for now. Revisit if instructional-DM friction is still too high after live use. |
| OAuth-based esr user registration | Spec §"Out of scope" | Manual `esr user add` for now. Real OAuth needs Feishu Open Platform integration. |
| **Yaml-ify adapter sidecar dispatch** (`@sidecar_dispatch`) | Workshop 2 | After Workshop 1 (slash routing) ships. `worker_supervisor.ex:45` map. Adding new adapter type today touches Elixir. |
| **Yaml-ify permissions registry** | Workshop 2 | Centralize the `permissions/0` callbacks scattered across `Esr.Admin`, `Esr.PeerServer`, future handlers. Single `permissions.yaml` listing perms + scope prefixes (would have prevented PR-21γ's `validate_scope` bug). Note: PR-4.4 dropped the file-system JSON dump but the in-memory registry remains scattered. |
| **Yaml-ify default values** (agent="cc", role="dev", start_cmd, kill_timeout) | Workshop 3 | `defaults.yaml`. Currently scattered across 5+ modules; tests + dev quirks suffer from no central spec. |
| **Yaml-ify rate-limit windows** (`@deny_dm_interval_ms`, `@guide_dm_interval_ms`) | Workshop 3 | Operator-tunable. Dev / prod / e2e want different values. |
| **Externalize doctor / help text to markdown** | Edge / cosmetic | Long Chinese heredoc strings in `Esr.Commands.Doctor`. Operator wants to tweak phrasing without restart. |
| **Per-workspace worktree path convention** | Speculative | Today PR-21θ hardcodes `<root>/.worktrees/<branch>`. Workspace yaml could carry `worktree_pattern:` to override (e.g. `<root>-<branch>` sibling-dir). |
| **Yaml file visualization / pretty-print** | New 2026-04-30 | After PR-21κ, the yaml surface grew: `slash-routes.yaml` + workspace JSON files (per-workspace, hybrid storage post-2026-05-06) + `users.yaml` + `capabilities.yaml` + `agents.yaml` + `adapters.yaml` + `plugins.yaml` + `manifest.yaml` (per plugin) — cross-references hard to follow. Candidates: (a) `/topology` slash, (b) `runtime/esr show` pretty-printer, (c) mermaid/graphviz at boot, (d) Phoenix LiveView dashboard. Brainstorm + scope decision needed. |
| **Auto-create session: meaningful default cwd** | New 2026-05-01 | When a chat with no live session receives non-slash text, FAA broadcasts `:new_chat_thread` and Scope.Router auto-creates a session. PR-21τ added a safety net (`pwd` fallback). User suggestion: use `$ESRD_HOME/<env>/<workspace>/sessions/<sid>/` so ESR self-manages the path. Tradeoff: claude has no git context there. Brainstorm before implementing. |
| **Spec: agent (cc) startup config first-class** | New 2026-05-01 | Today CC's startup is a stack of moving parts: agents.yaml's `cc` entry, workspace `start_cmd` (now in `workspace.json` post-2026-05-06), scripts/esr-cc.sh, scripts/esr-cc.local.sh, launchd plist EnvironmentVariables, claude's own `~/.claude/` cached creds. Operator-on-fresh-host hitting `Please run /login - 403` has no single doc. Candidates: (a) agents.yaml `preconditions:` block + startup validator, (b) `/doctor` agent-aware (Anthropic API reachability + cred check), (c) deploy doc enumerates the layers. Triggered by 2026-04-30 PR-21κ live-test where 4+ layers had to be debugged. |
| **Reliability: PtyProcess-death zombie session** | New 2026-05-01 (renamed from "tmux-death" — PR-22 replaced tmux with PtyProcess) | When PtyProcess crashes, the rest of the session pipeline (cc_process, FCP, SessionRegistry) needs to notice. Likely fix: supervisor strategy `:one_for_all` (full session teardown + auto-recreate), OR explicit `Scope.Registry.unregister_session/1` in PtyProcess's terminate. Brainstorm before implementing. |
| **BEAM lesson note: supervisor reentrancy in child init** | New 2026-05-01 | PR-21ψ deadlock taught: never call back into your own supervisor (or its children) from within a child's `init/1`. `DynamicSupervisor.start_child` is synchronous; cycling back into the supervisor's mailbox → infinite wait. Escape hatches: `Process.send_after`, `{:continue, :step}`, separate process. Worth a `docs/notes/beam-init-reentrancy.md` so this doesn't repeat. |
| **`/switch-session name=<n>` slash for explicit chat-current rebind** | New 2026-05-01 | The chat-current overwrite shipped in PR-21l is implicit: a second `/new-session` silently displaces the prior session. UX-wise an explicit `/switch-session` is preferable. Implementation: parked_sessions map per (chat, app) + current_sid pointer; `slash-routes.yaml` entry for `session_switch`; new `Esr.Commands.Scope.Switch` resolves `name=<n>` via PR-21g's `claim_uri` index. Real design work (~150–200 LOC + tests + spec). |
| **Feishu file / image / audio inbound** | New 2026-05-02 | FAA + FCP only handle `msg_type: text`. Feishu's `im.message.receive_v1` also delivers `file` / `image` / `audio` / `media` / `sticker` / `post` / `interactive` payloads with `file_key` references that need to be downloaded via Lark API. cc_mcp's `send_file` exists for outbound; inbound side has no peer or handler. Required: (1) FCP recognizes non-text, (2) python feishu adapter resolves `file_key` → bytes via the Lark API, (3) deliver to claude as `<channel kind="file" path="…">` or stash on disk + URL pointer. |
| **`/session new <name>` redesign — auto-cwd + add-dir + enter-worktree** | New 2026-05-02 | Today's `/new-session default name=X root=Y worktree=Z` packs four parameters; redundancy between `default`/`root` and between `name`/`worktree` is brittle. User-proposed refactor: `/session new <NAME>` (auto-cwd at `$ESRD_HOME/<env>/users/<username>/sessions/<NAME>/`), `/session add-dir <PATH>` (registers project dir + claude `--add-dir`), `/session enter-worktree <BRANCH>` (creates worktree + chdirs). Brainstorm + spec before implementation. |
| **Pre-merge-dev gate: agent-browser content assertion (3 of 3-2-1)** | New 2026-05-04 — partial in PR #184 | Current gate (`scripts/hooks/pre-merge-dev-gate.sh` §2b) checks `data-opened-cols`/`-rows` dataset which populate at xterm.js init BEFORE WS data. PR #184 added partial content assertion (item 2 of 3-2-1). Item 1 (RCA) and item 3 (full content) still pending. Memory rule §K mandates agent-browser for web/UI work. |
| **R7.5: Esr.Commands.Scope.BranchEnd split** | New 2026-05-04 | BranchEnd at 453 LOC bundles 4 separable concerns: cleanup handshake, worktree script execution, branches.yaml mutation, routing.yaml mutation. Splittable into orchestrator (~50 LOC) + `Esr.Resource.Branches` + `Esr.Worktree.Cleanup`. Spec needed before implementation. |

## Pending — observability / ops

| What | Notes |
|---|---|
| `ChannelClient` align with phx-py reference | `docs/futures/channel-client-phx-py-alignment.md` — full audit of self-hosted Phoenix client vs phx-py best practices. PR-21l fixed heartbeat; per-call timeout + connection-state events still missing. |
| ExDoc-based runtime API docs | The previous `gen-docs.sh` script (covered click CLI + cli_channel.ex dispatch topics) was deleted in PR-223 along with the Python CLI. The live source-of-truth for slashes is now `runtime/priv/slash-routes.default.yaml` + `EsrWeb.SlashSchemaController`'s `/admin/slash_schema.json` endpoint that `runtime/esr describe-slashes` queries. Standalone ExDoc for internal Elixir modules is still missing. |
| Per-session role override | Workspace dictates `role:` today; per-session override mentioned in spec out-of-scope. |
| Cross-workspace branch sharing | Speculative; spec out-of-scope. |
| Worktree GC sweep | Periodic prune of branchless worktrees. Operator runs `git worktree prune` manually for now. |

## Done — recent (last ~15 PRs, for context)

Older PRs are in git log.

- feature/workspace-vs-code-redesign-impl — **workspace VS-Code-style redesign shipped after merge**: hybrid storage (`workspace.json` per workspace, ESR-bound or repo-bound), UUID identity, `folders[]` replacing single `root`, `Workspace.Watcher` deleted (CLI invalidates Registry inline), 1:N workspace-to-sessions, 14 new `/workspace*` slashes, `default` workspace auto-created at boot. Spec: `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md`.
- PR #178 — R11 post-mortem note (e2e lessons + agent-browser content gate TODO)
- PR #179 — plugin work specs (Core Decoupling A + Plugin Mechanism B)
- PR #180–#186 — Plugin Track 0 / Phase 1: Loader + Manifest + 3 stubs + RCA helpers + boot bridge
- PR #187 — `tools/esr-debug` reusable RCA helper bundle
- PR #188 — Phase 2/3/4 plugin work specs (中英双语) + initial todo.md update
- PR #190–#191 — channel-server port debt audit + delete daemon.py + dev_channels_unblock.sh
- PR #192 — Phase 2-3-4 execution plan + AFK operating principles
- PR #193 — delete voice plugin (never productionized) (Phase 2 PR-2.0)
- PR #194 — `GET /admin/slash_schema.json` schema dump (Phase 2 PR-2.1)
- PR #195–#197 — `Esr.Slash.ReplyTarget` behaviour + 4 impls (Phase 2 PR-2.2 / PR-2.3a / PR-2.3b)
- PR #198 — rename `Esr.Admin.Commands.*` → `Esr.Commands.*` (Phase 2 PR-2.4)
- PR #199 — delete `Esr.Admin.Dispatcher`; SlashHandler unifies dispatch (Phase 2 PR-2.3b-2)
- PR #200–#201 — `Esr.Cli.Main` escript skeleton + subcommands (Phase 2 PR-2.5/PR-2.6)
- PR #202 — close Phase 2 (dev-guide CLI install + completion note)
- PR #203 — remove fallback Sidecar registrations (Phase 3 PR-3.1)
- PR #204 — `Esr.Entity.Agent.StatefulRegistry` runtime API (Phase 3 PR-3.2)
- PR #205 — move feishu modules to `runtime/lib/esr/plugins/feishu/` (Phase 3 PR-3.3)
- PR #206 — move cc modules to `runtime/lib/esr/plugins/claude_code/` (Phase 3 PR-3.6)
- PR #207 — cc plugin no longer references "feishu" (Phase 3 PR-3.7)
- PR #208 — collapse `Esr.Admin.*` → `Esr.Slash.*` (Phase 4 PR-4.3)
- PR #209 — drop `permissions_registry.json` cross-language dump (Phase 4 PR-4.4)
- PR #210 — Phase 3 + Phase 4 closing status note
- PR #211 — e2e CLI dual-rail switch (Phase A)
- PR #212 — escript output format + `/actors` slash route (Phase B-1)
- PR #213 — delete StatefulRegistry hardcoded fallbacks (Phase D-1)
- PR #214 — escript click-style flag parser + `/cap {list,show,who-can,grant,revoke}` (Phase B-2)
- PR #215 — `/users {list,add,remove,bind-feishu,unbind-feishu}` slash routes (Phase B-3)
- PR #216 — delete `py/src/esr/cli/` (Phase C — reverted in #218)
- PR #217 — manifest validation gate test (Phase F / PR-4.5)
- PR #218 — revert Phase C (final_gate.sh was broken)
- PR #219 — feishu plugin startup hook + `Esr.Plugin.Loader.run_startup/0` (Phase 3 PR-3.4)
- PR #220 — cc_mcp HTTP MCP transport (esrd-hosted) (Phase 3 PR-3.5)
- PR #221 — PostToolUse self-check hook after openclaw-channel calls
- PR #222 — cli-channel→slash migration: every `cli:*` handler → `Esr.Commands.*` slash; cli_channel.ex shrinks to a 30-line protocol shell; new `Esr.Resource.Workspace.Describe` single security boundary
- PR #223 — scenarios/ + Python CLI removal: ~10k LOC deletion + 3 unit-test gaps closed (`Esr.Commands.{Deadletter,Debug,Trace}`)
