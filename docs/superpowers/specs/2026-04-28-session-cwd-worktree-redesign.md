# PR-20 Spec: Session URI + cwd/worktree redesign + multi-user

**Status:** v3 — all open Qs answered (2026-04-29). Ready for implementation.
**Author:** allen (linyilun) + claude pair-prog session.
**Date:** 2026-04-28 (drafted), 2026-04-29 (locked).
**Implementation PR:** PR-20.

## Background

Today's mental model (v0.2):

```
adapters.yaml:        "esr_dev_helper" → {feishu app credentials}
workspaces.yaml:      "esr-dev"         → {cwd, start_cmd, role, chats}
/new-session esr-dev tag=root  → cwd = workspaces["esr-dev"].cwd
/new-session esr-dev tag=child → ALSO cwd = workspaces["esr-dev"].cwd
                                  ↑ two CCs editing same files
```

User's pain (verbatim, 2026-04-28 08:09):

> 我不希望 new-session 全部在同一个 workspace 中，这样容易出现同时修改代码的情况。我希望每次 new-session 都要显式指定工作目录（cwd），tag 应该改名叫 worktree。

User's clarified model (2026-04-28 08:31):

> 1. 先不用考虑兼容，现在 esrd 还没有实际投入使用
> 2. 我倾向于 /new-session 显式指定：
>    a. **name**: session 的名字，tmux、CC 等等都使用这个名字
>    b. **cwd**: 工作目录
>    c. **worktree name**: fork 的分支名，默认从 main fork，需要切换可以手动去切换
>    d. 每个 worktree 只有一个 session，多个 session 使用一个 worktree 不允许

User's URI model (2026-04-29 02:49 + 02:58 + 03:02 + 03:07):

> 所有的命名都要和 uri 机制对应，`esr://<env>/<username>/<workspace>/<session-name>` (注意不是 esrd 而是 esr://), 考虑到每个 session 都有对应的 proxy，这样比较合理。
> tmux 的命名 = `<env>_<username>_<workspace>_<session-name>` (URI path 转译)。
> 唯一性范围 = esrd instance（user namespace 中的 user 不是 OS user，是 esr user — linyilun, yaoshengyue 这些）。
> 需要引入 esr user 的概念，feishu id 等需要通过 cli 绑定 user，权限作用在 esr user 上。
> /end-session 时弹出提示（两步交互）。
> 现在就有第二个人（yaoshengyue）参与开发。

## Locked decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | No backwards compatibility shim. esrd has 0 live sessions; PR-20 is a clean break. | Caps + sessions.yaml + workspaces.yaml all reset. |
| **D2** | `/new-session` takes three explicit args: `name`, `cwd`, `worktree`. No derivation from workspace. | User's 2026-04-28 08:31 #2. |
| **D3** | Session is identified by URI: **`esr://<env>/<username>/<workspace>/<session-name>`**. URI is the primary key in `sessions.yaml`. | User's 2026-04-29 02:49 #1. `esr://` (proxy face), not `esrd://` (daemon face). |
| **D4** | tmux session name = URI path translated `/` → `_`: **`<env>_<username>_<workspace>_<session-name>`**. | User's 2026-04-29 02:58 + 03:02 F2. env in tmux name (clearer); also avoids cross-env collision. |
| **D5** | `cwd` = git worktree path (where CC's process runs). Always a worktree, never a plain dir. | User's 2026-04-29 02:17 + my A/B clarification → user picked "cwd is worktree". |
| **D6** | `worktree` = git branch name. Always forked from **`origin/main`** (not local `main`) via `git -C <root> worktree add <cwd> -b <worktree> origin/main`. Operator switches branches manually post-spawn if needed. Using `origin/main` avoids the "local main is stale" footgun. | User's 2026-04-28 08:31 #2c + code-reviewer fact-check (local-main-stale risk). |
| **D7** | `root` = each workspace's main git repo. Stored in `workspaces.yaml` as `root:` field. esrd does `git -C <root> worktree add <cwd> -b <worktree> main` from there. | User's 2026-04-29 02:49 vocab. |
| **D8** | Uniqueness — single esrd instance scope: within one `<env>`, both `(username, workspace, name)` AND `(username, workspace, worktree-branch)` must be unique. dev / prod envs don't constrain each other. | User's 2026-04-29 02:58 F3 + 03:02 #3. |
| **D9** | esr user is a first-class concept. New `users.yaml` registry; feishu id → esr user binding via CLI. caps system re-keys onto esr user. yaoshengyue is currently developing alongside linyilun, so multi-user is day-1 (not YAGNI). | User's 2026-04-29 03:02 F1 + F5. |
| **D10** | `<env>` and `<username>` derivation: `<env>` from `$ESR_INSTANCE` env var (existing); `<username>` resolved from inbound `<channel user_id="ou_...">` lookup against `users.yaml`. CLI-direct fallback: required `--as-user <name>` flag. | Implied by F1. CLI without IM identity needs explicit user. |
| **D11** | tmux socket per esrd env: `tmux -S $ESRD_HOME/$ESR_INSTANCE/tmux.sock`. Avoids polluting user's other tmux sessions and gives extra isolation even though tmux name already disambiguates. | User's 2026-04-29 03:02 F2 + my hardening. |
| **D12** | `/end-session <name>` two-step interactive confirm. Step 1: status report ("worktree clean / dirty, reply `confirm` to prune / `cancel` to keep"). Step 2: operator's next message consumed by channel server's pending-action state machine. | User's 2026-04-29 03:02 F4 + 03:07 selection (a). |
| **D13** | Character set for `<username>` and `<session-name>`: ASCII alphanumeric + `-` + `_`. Validates at insert time. Aligns with PR-M adapter naming rule. | Hygiene; URI must be safe. |
| **D14** | **Single `/new-session` grammar across Elixir + Python parsers.** Today there are two divergent parsers (Elixir `SlashHandler` uses `--agent --dir`; Python `feishu_app/on_msg.py` uses positional + `tag=`). PR-20 unifies both on `name=<…> cwd=<…> worktree=<…>` (plus positional workspace as the leading arg). | Code-reviewer fact-check found the divergence; spec must commit to single grammar. |
| **D15** | **`PendingActions` interception point**: the state machine intercepts inbound messages in `Esr.Peers.FeishuAppAdapter.handle_upstream/2` (or equivalent entry hook) BEFORE slash-command parsing AND BEFORE active-thread fallback routing. `confirm` / `cancel` from an operator with a pending action consumed there; otherwise message proceeds normally. TTL = 60 s. | Code-reviewer flagged silent interception-point gap; bare words `confirm` / `cancel` would otherwise route as ordinary messages to the active thread. |

## Proposed shape

### Session URI (D3)

```
esr://<env>/<username>/<workspace>/<session-name>

example: esr://default/linyilun/esr-dev/feature-foo
         esr://dev/yaoshengyue/voice-gateway/spike-1
```

Components:
- `<env>` — esrd environment (`default`, `dev`, …) from `$ESR_INSTANCE`.
- `<username>` — esr user (linyilun, yaoshengyue, …); resolved from feishu id binding.
- `<workspace>` — workspace name from `workspaces.yaml`.
- `<session-name>` — operator-supplied session label.

### Workspace yaml schema (D7, D9)

```yaml
# $ESRD_HOME/$ESR_INSTANCE/workspaces.yaml
workspaces:
  esr-dev:
    owner: linyilun                          # NEW (D9) — esr user this workspace belongs to
    root: /Users/h2oslabs/Workspace/esr      # NEW (D7) — main git repo
    role: dev
    start_cmd: scripts/esr-cc.sh
    chats:
      - chat_id: oc_xxx
        app_id: cli_xxx
    metadata: { ... }                        # unchanged (PR-F)
    neighbors: [ ... ]                       # unchanged (PR-C)
    # cwd: <DELETED>                         — was workspace-level, now per-session
```

### Users yaml (D9, D10)

```yaml
# $ESRD_HOME/$ESR_INSTANCE/users.yaml      ← NEW file
users:
  linyilun:
    feishu_ids:
      - ou_6b11faf8e93aedfb9d3857b9cc23b9e7
  yaoshengyue:
    feishu_ids:
      - ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Multiple feishu ids per esr user supported (one human can use multi accounts).

### Sessions yaml (D3)

```yaml
# $ESRD_HOME/$ESR_INSTANCE/sessions.yaml
sessions:
  "esr://default/linyilun/esr-dev/feature-foo":     # full URI as key
    cwd: /Users/h2oslabs/Workspace/esr-feature-foo
    worktree: feature-foo
    pid: 12345
    started_at: 2026-04-29T03:00:00Z
    tmux_session: default_linyilun_esr-dev_feature-foo
```

### Slash command (D2)

```
/new-session <workspace> name=<session-name> cwd=<path> worktree=<branch>

example:
  /new-session esr-dev name=feature-foo cwd=/Users/h2oslabs/Workspace/esr-feature-foo worktree=feature-foo
```

Runtime sequence on `/new-session`:

1. Resolve `<username>` from inbound channel envelope's `user_id`, looking up `users.yaml`. Reject if no binding.
2. Construct URI `esr://<env>/<username>/<workspace>/<name>`.
3. Validate D8 uniqueness in `sessions.yaml` (no live URI; no live `(username, workspace, worktree)` collision).
4. Validate D13 character set on `<name>`.
5. Resolve workspace's `root:` field from `workspaces.yaml`.
6. If `cwd` does not exist on disk: run `git -C <root> worktree add <cwd> -b <worktree> main`. Errors abort spawn.
7. Spawn CC in tmux: `tmux -S $ESRD_HOME/$ESR_INSTANCE/tmux.sock new-session -d -s <env>_<username>_<workspace>_<name> -c <cwd> ...`.
8. Append session to `sessions.yaml` keyed by URI.

### `/end-session` two-step (D12)

```
operator: /end-session feature-foo
         (resolves via current channel envelope's user → URI)
esrd:    Session esr://default/linyilun/esr-dev/feature-foo at /path
         worktree feature-foo: clean ✓
         Reply `confirm` to prune worktree + remove session,
         or `cancel` to keep worktree on disk (session still ends).
operator: confirm
esrd:    Pruned /path. Session ended.
```

Channel server gains a small **pending-action state machine**: when esrd emits a "confirm-or-cancel" prompt, the next inbound message from that operator+chat is intercepted as the answer. State expires after 60 s.

This pattern is reusable for any future destructive op (`/remove-workspace`, `/unbind-user`, `/destroy-adapter`).

## Implementation outline

### Runtime (Elixir, ~400 LOC)

1. **`Esr.Users`** (new module) — load/save `users.yaml`; resolve `feishu_id → username`; CRUD via `cli:users:*` topics.
2. **`Esr.Sessions.URI`** (new module) — parse/build URI; D13 validation.
3. **`Esr.Workspaces.Registry`** — schema bump (`runtime/lib/esr/workspaces/registry.ex:28-32, 84-111`): add `:owner` + `:root` to `Workspace` struct; drop `:cwd`; update field-by-field loader. FSEvents reload unchanged. `metadata` and `neighbors` survive (already in struct).
4. **`Esr.SessionRegistry`** (`runtime/lib/esr/session_registry.ex:26-50, 98-116`) — **net-new uniqueness logic** (NOT an extension): the registry today is keyed by `(chat_id, app_id, thread_id)` (PR-A T1 ETS layout) and has no name-uniqueness check at all. PR-20 adds two new ETS indexes: `(env, username, workspace, name) → URI` and `(env, username, workspace, worktree-branch) → URI`. Maintained on register/unregister with collision-rejection up front. ~50 LOC.
5. **`Esr.Worktree`** (new module) — wrap `git -C <root> worktree add <cwd> -b <branch> origin/main` (D6, **`origin/main` not local `main`**) / `git status --porcelain` / `git worktree remove`. Structured error from `System.cmd`.
6. **tmux socket** — Elixir side already plumbed (`runtime/lib/esr/application.ex:215-239` `:tmux_socket_override`; `runtime/lib/esr/peers/tmux_process.ex:87-114, 222-227, 410-414, 485-510`; launchd plists already set `ESR_TMUX_SOCKET`). **Remaining work**: `adapters/cc_tmux/src/esr_cc_tmux/adapter.py:117,140` calls `tmux new-session` / `send-keys` with no `-S`. Either thread `tmux_socket` through `AdapterConfig.config["subprocess"]` or formally **deprecate cc_tmux** (cc_mcp+TmuxProcess is the new path; cc_tmux is referenced from `worker_supervisor.ex:46` + tests). Recommendation: deprecate.
7. **`Esr.Peers.SlashHandler` + Python `feishu_app/on_msg.py`** — **D14 grammar unification**. Today divergent: Elixir uses `--agent --dir`, Python uses positional + `tag=`. Rewrite both onto `name=<…> cwd=<…> worktree=<…>` (positional workspace as leading arg). Affected files (renames + parse rewrite):
   - `runtime/lib/esr/peers/slash_handler.ex:124-179`
   - `handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py:80-100`
   - `handlers/feishu_app/tests/test_on_msg.py:34`
   - User-facing onboarding DM text: `runtime/lib/esr/peers/feishu_app_adapter.ex:375` (says "/new-session esr-dev tag=root" today; rewrite to new grammar)
   - Live signature gate: `scripts/final_gate.sh:118, 318, 327, 388, 432-434, 493-497`
   - Mock: `scripts/mock_feishu.py:359`
   - E2E fixtures: `tests/e2e/scenarios/05_topology_routing.sh:58, 67, 76`; `tests/e2e/scenarios/common.sh:378`
   - Comment: `tests/e2e/scenarios/03_tmux_attach_edit.sh:7`
8. **`EsrWeb.CliChannel`** — new dispatch clauses `cli:users:*`. `/new-session` + `/end-session` re-shaped per D2 / D12.
9. **`EsrWeb.PendingActions`** (new) — TTL state machine. **D15 interception point**: hook in `Esr.Peers.FeishuAppAdapter.handle_upstream/2` (or equivalent inbound entry) BEFORE slash parser AND BEFORE active-thread fallback. `PendingActions.intercept?(envelope)` returns `{:consume, :confirm | :cancel}` or `:passthrough`.
10. **`Esr.Capabilities.Grants`** rekey — Grants module itself does string-equality on `principal_id` (`runtime/lib/esr/capabilities/grants.ex:25-31`), so the module is unchanged. The rekey happens at envelope-construction sites: `peer_server.ex:243`, `peers/feishu_chat_proxy.ex:362`, `admin/dispatcher.ex:188`, `admin/commands/session/new.ex:121`. Each translates `ou_*` → esr username via `Esr.Users.lookup/1` before populating `principal_id`. Plus:
    - `capabilities.yaml`'s `kind: feishu_user` field → rename to `kind: esr_user` (informational; not used for matching)
    - `ESR_BOOTSTRAP_PRINCIPAL_ID` env var now accepts an esr username (was `ou_*`); update auto-generated comment in capabilities.yaml.
11. **`scripts/esr-cc.sh`** — line 45-52 reads `cwd` from yaml via `yq`. With `cwd:` removed, switch to relying on tmux's `-c <cwd>` already setting pwd at spawn (no `cd` needed in the script). Drop the `yq` lookup. Line 79-86 uses `session-ids.yaml` keyed by `<ws>:<sid>` for `claude --resume` — bump key shape to URI (`esr://...`) and wipe in migration.

### Python CLI (~150 LOC)

New click subgroup `esr user`:
- `esr user add <name>`
- `esr user list`
- `esr user remove <name>`
- `esr user bind-feishu <name> <feishu_user_id>`
- `esr user unbind-feishu <name> <feishu_user_id>`

Modified:
- `esr workspace add` (`py/src/esr/cli/main.py:1393-1439`) gains `--owner <esr-user>` + `--root <repo-path>` required flags.
- `py/src/esr/workspaces.py:24-49` `Workspace` dataclass + `read_workspaces` / `write_workspace` schema bump (drop `cwd`, add `owner` + `root`).
- `esr session new` takes 3 named args; supports `--as-user <name>` for CLI-direct fallback (D10).
- `esr session ls` prints URIs.
- `esr session end` triggers the two-step confirm flow.

### Auto-docs (CLAUDE.md convention)

After touching `py/src/esr/cli/**` or any `dispatch/2` clause, run `bash scripts/gen-docs.sh` and commit regenerated [`docs/cli-reference.md`](../../cli-reference.md) + [`docs/runtime-channel-reference.md`](../../runtime-channel-reference.md) in the same PR.

### Tests

| Layer | What |
|---|---|
| Unit (Elixir) | URI parse/build, D8 collision tuples (both name + worktree), `Esr.Users` CRUD, `PendingActions` TTL expiry, grammar parser (single grammar) |
| Unit (Python) | `esr user *` click commands; arg validation; `Workspace` dataclass schema |
| E2E | New scenario `0X_pr20_multi_user_worktree.sh`: register linyilun + yaoshengyue; spawn 2 sessions same workspace; verify URI uniqueness, separate worktrees, separate tmux sessions on per-env socket |
| Cap regression | Existing cap tests rekeyed to esr user; verify cap grant works post-`esr user bind-feishu` |
| Live gate | `scripts/final_gate.sh` updated to new grammar; signature still passes |

### LOC budget

Updated total: **~700-950 LOC**.

| Area | LOC |
|---|---|
| Elixir runtime | ~400 |
| Python CLI + handlers | ~150 |
| Tests (Elixir + Python + E2E) | ~200 |
| Shell + scripts (esr-cc.sh, final_gate.sh, mock_feishu.py) | ~60 |
| Docs (this spec + architecture.md update + dev-guide.md user/auth section) | ~75 |

## Out of scope (deferred)

- **Per-session role override** — workspace dictates `role:`; per-session future PR.
- **Cross-workspace branch sharing** — speculative.
- **Worktree GC sweep** — periodic prune of branchless worktrees; operator handles for now.
- **Multiple feishu apps per esr user** — `users.yaml` schema allows but mapping is per-id; no aliasing across apps.
- **OAuth-based esr user registration** — manual `esr user add` for now.
- **`describe_topology` exposure of `users.yaml`** — default-deny in PR-20. The MCP tool currently filters `workspaces.yaml` via per-field whitelist (`runtime/lib/esr/peer_server.ex:857-872` `filter_workspace_for_describe`). PR-20 does not extend this to `users.yaml` at all: feishu ids are sensitive, and there is no concrete LLM use case for "which other esr users exist" today. Future PR can add an opt-in filter (whitelist `username` only, drop `feishu_ids`) if a use case arises.

## Subagent-review findings (resolved 2026-04-29)

`superpowers:code-reviewer` was run against spec v3 on 2026-04-29. Findings folded into v3.1:

| # | Finding | Resolution in spec |
|---|---|---|
| 1 | `git worktree add … main` would fork from stale local `main` if not pulled | D6 amended: use `origin/main` (no manual fetch step required) |
| 2 | `SessionRegistry` is keyed by `(chat_id, app_id, thread_id)`, not name — D8 is net-new logic, not extension | Impl outline 4 rewritten; +50 LOC budgeted |
| 3 | Elixir tmux socket plumbing already exists (PR-N era); cc_tmux Python adapter still uses default socket | Impl outline 6 narrowed: deprecate cc_tmux or thread `tmux_socket` through `AdapterConfig.config["subprocess"]` |
| 4 | TWO `/new-session` parsers diverge today (Elixir `--agent --dir` vs Python positional + `tag=`) | New decision **D14**: unify on `name=/cwd=/worktree=` across both; impl outline 7 enumerates all 9 affected files |
| 5 | `EsrWeb.PendingActions` interception point unspecified; bare `confirm`/`cancel` would route as ordinary messages | New decision **D15**: hook in `feishu_app_adapter.handle_upstream/2` before slash parser + active-thread fallback |
| 6 | `cwd:` removal breaks `scripts/esr-cc.sh:45-52` (yq + cd into cwd) | Impl outline 11 added: drop `yq` lookup, rely on tmux `-c <cwd>` |
| 7 | Caps Grants module unchanged but `kind: feishu_user` becomes misnomer; `ESR_BOOTSTRAP_PRINCIPAL_ID` semantics shifts | Impl outline 10 rewritten: rename `kind` to `esr_user`; bootstrap env var accepts username |
| 8 | Migration missed `session-ids.yaml` (`esr-cc.sh:79-86` uses it for `claude --resume`) | Migration § §3a added |
| 9 | `describe_topology` filter — `users.yaml` should be default-deny, not just filter feishu_ids | Out-of-scope §: do not expose `users.yaml` to MCP tool at all (no LLM use case) |

Findings cited file:line throughout `runtime/lib/esr/`, `handlers/feishu_app/`, `adapters/cc_tmux/`, `scripts/`, `py/src/esr/`. See git history of this spec file for the full subagent transcript context.

## Migration to PR-20

D1 = clean break. On PR-20 merge, for each esrd env (`default`, `dev`):
1. Operator stops esrd (`launchctl unload com.ezagent.esrd[-dev].plist`).
2. `rm $ESRD_HOME/$ESR_INSTANCE/sessions.yaml` (no live sessions).
3. `rm $ESRD_HOME/$ESR_INSTANCE/session-ids.yaml` (key shape changes from `<ws>:<sid>` to URI).
4. `rm $ESRD_HOME/$ESR_INSTANCE/capabilities.yaml` — caps reset; principal IDs now esr usernames.
5. Edit `workspaces.yaml`: add `owner: <esr-user>` + `root: <repo-path>` to each workspace; remove `cwd:`.
6. Create `users.yaml`:
   ```yaml
   users:
     linyilun:
       feishu_ids: [ou_6b11faf8e93aedfb9d3857b9cc23b9e7]
     yaoshengyue:
       feishu_ids: [ou_<yaoshengyue's id>]
   ```
7. (If using bootstrap principal) Set `ESR_BOOTSTRAP_PRINCIPAL_ID=linyilun` (was `ou_*`).
8. Restart esrd.
9. From inside any registered Feishu chat, run `/new-session <workspace> name=<...> cwd=<...> worktree=<...>` — first session triggers cap grant against `linyilun` (or whichever esr user is bootstrap).

Migration script optional (small enough to do by hand for 2 envs × N workspaces). If deployed in more environments, a `scripts/migrate-pr20.sh` could be added — but YAGNI for current scope.

## Next step

Spec v3 locked. Run `superpowers:code-reviewer` subagent for fact-check pass; address any findings; then open PR-20.
