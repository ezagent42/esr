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
| **D6** | `worktree` = git branch name. Always forked from `main` initially via `git -C <root> worktree add <cwd> -b <worktree> main`. Switch branches manually post-spawn if needed. | User's 2026-04-28 08:31 #2c. |
| **D7** | `root` = each workspace's main git repo. Stored in `workspaces.yaml` as `root:` field. esrd does `git -C <root> worktree add <cwd> -b <worktree> main` from there. | User's 2026-04-29 02:49 vocab. |
| **D8** | Uniqueness — single esrd instance scope: within one `<env>`, both `(username, workspace, name)` AND `(username, workspace, worktree-branch)` must be unique. dev / prod envs don't constrain each other. | User's 2026-04-29 02:58 F3 + 03:02 #3. |
| **D9** | esr user is a first-class concept. New `users.yaml` registry; feishu id → esr user binding via CLI. caps system re-keys onto esr user. yaoshengyue is currently developing alongside linyilun, so multi-user is day-1 (not YAGNI). | User's 2026-04-29 03:02 F1 + F5. |
| **D10** | `<env>` and `<username>` derivation: `<env>` from `$ESR_INSTANCE` env var (existing); `<username>` resolved from inbound `<channel user_id="ou_...">` lookup against `users.yaml`. CLI-direct fallback: required `--as-user <name>` flag. | Implied by F1. CLI without IM identity needs explicit user. |
| **D11** | tmux socket per esrd env: `tmux -S $ESRD_HOME/$ESR_INSTANCE/tmux.sock`. Avoids polluting user's other tmux sessions and gives extra isolation even though tmux name already disambiguates. | User's 2026-04-29 03:02 F2 + my hardening. |
| **D12** | `/end-session <name>` two-step interactive confirm. Step 1: status report ("worktree clean / dirty, reply `confirm` to prune / `cancel` to keep"). Step 2: operator's next message consumed by channel server's pending-action state machine. | User's 2026-04-29 03:02 F4 + 03:07 selection (a). |
| **D13** | Character set for `<username>` and `<session-name>`: ASCII alphanumeric + `-` + `_`. Validates at insert time. Aligns with PR-M adapter naming rule. | Hygiene; URI must be safe. |

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

### Runtime (Elixir, ~350 LOC)

1. **`Esr.Users`** (new module) — load/save `users.yaml`; resolve `feishu_id → username`; CRUD via `cli:users:*` topics.
2. **`Esr.Sessions.URI`** (new module) — parse/build URI; D13 validation.
3. **`Esr.Workspaces`** — schema migration: load `root:` and `owner:` fields; drop `cwd:`. FSEvents reload unchanged.
4. **`Esr.SessionRegistry`** — re-key from `name` → URI. D8 collision check expanded to cover worktree-branch tuple.
5. **`Esr.Worktree`** (new module) — wrap `git worktree add` / `git status --porcelain` / `git worktree remove`. Macro for `System.cmd("git", ...)` with structured error.
6. **`Esr.Tmux`** — switch to `tmux -S $ESRD_HOME/$ESR_INSTANCE/tmux.sock` everywhere. Update `scripts/esr-cc.sh`.
7. **`EsrWeb.CliChannel`** — new dispatch clauses: `cli:users:*`. `/new-session` and `/end-session` clauses re-shaped per D2 / D12.
8. **`EsrWeb.PendingActions`** (new) — TTL state machine for two-step confirm.
9. **`Esr.Caps`** — rekey storage from feishu identity → esr user. D1 = wipe existing caps, fresh start.

### Python CLI (~120 LOC)

New click subgroup `esr user`:
- `esr user add <name>`
- `esr user list`
- `esr user remove <name>`
- `esr user bind-feishu <name> <feishu_user_id>`
- `esr user unbind-feishu <name> <feishu_user_id>`

Modified:
- `esr workspace add` gains `--owner <esr-user>` and `--root <repo-path>` required flags.
- `esr session new` (or however `/new-session` shells out) takes the 3 named args; supports `--as-user <name>` for CLI-direct fallback (D10).
- `esr session ls` prints URIs.
- `esr session end` triggers the two-step confirm flow.

### Auto-docs (CLAUDE.md convention)

After touching `py/src/esr/cli/**` or any `dispatch/2` clause, run `bash scripts/gen-docs.sh` and commit regenerated [`docs/cli-reference.md`](../../cli-reference.md) + [`docs/runtime-channel-reference.md`](../../runtime-channel-reference.md) in the same PR.

### Tests

| Layer | What |
|---|---|
| Unit (Elixir) | URI parse/build, D8 collision tuples, `Esr.Users` CRUD, pending-action TTL expiry |
| Unit (Python) | `esr user *` click commands; arg validation |
| E2E | New scenario `0X_pr20_multi_user_worktree.sh`: register linyilun + yaoshengyue; spawn 2 sessions same workspace; verify URI uniqueness, separate worktrees, separate tmux sessions on shared socket |
| Cap regression | Existing cap tests rekeyed to esr user; verify cap grant works for `esr user bind-feishu`-resolved identity |

### LOC budget

Updated total: **~600-800 LOC**.

| Area | LOC |
|---|---|
| Elixir runtime | ~350 |
| Python CLI | ~120 |
| Tests (Elixir + Python + E2E) | ~150 |
| Docs (this spec + architecture.md update + dev-guide.md user/auth section) | ~50 |

## Out of scope (deferred)

- **Per-session role override** — workspace dictates `role:`; per-session future PR.
- **Cross-workspace branch sharing** — speculative.
- **Worktree GC sweep** — periodic prune of branchless worktrees; operator handles for now.
- **Multiple feishu apps per esr user** — `users.yaml` schema allows but mapping is per-id; no aliasing across apps.
- **OAuth-based esr user registration** — manual `esr user add` for now.

## Subagent-review checklist

`superpowers:code-reviewer` fact-checks before PR-20 opens:

- [ ] `git worktree add <path> -b <new_branch> main` works on macOS git 2.40+. Specifically: does `main` need to be `origin/main` if local `main` is behind? Does `git -C <root>` work even if cwd of the calling process differs?
- [ ] Existing `Esr.SessionRegistry` collision detection extends to `(username, workspace, worktree)` tuple without major refactor.
- [ ] Existing tmux usage in `scripts/esr-cc.sh`, `scripts/esr.sh`, and `runtime/lib/esr_web/cli_channel.ex` doesn't assume default socket — survey all `tmux …` invocations and confirm they thread through a configurable socket path.
- [ ] Existing cap system storage location and key shape — confirm rekeying from feishu identity to esr user fits within current modules without schema migration tooling (D1 says wipe).
- [ ] Channel server has no existing "pending-action" mechanism — confirm `EsrWeb.PendingActions` is greenfield, doesn't conflict with existing rate-limit / dedup logic for deny-DM / guide-DM (PR-N).
- [ ] `workspaces.yaml` `metadata:` (PR-F) and `neighbors:` (PR-C) survive the schema change with `owner:` + `root:` added and `cwd:` removed.
- [ ] No existing test fixture relies on `tag=` being load-bearing in a way that the rename to `name=` / `worktree=` would silently break.
- [ ] `describe_topology` MCP tool (CLAUDE.md gotcha #3) — `users.yaml` content should NOT be exposed verbatim to LLM (feishu ids might be considered sensitive); confirm this is filtered at the response boundary, like `env:` and `cwd:` already are.

## Migration to PR-20

D1 = clean break. On PR-20 merge:
1. Operator stops esrd.
2. `rm $ESRD_HOME/$ESR_INSTANCE/sessions.yaml` (no live sessions).
3. `rm $ESRD_HOME/$ESR_INSTANCE/caps.{yaml,db}` (whatever the existing path is) — caps reset.
4. Edit `workspaces.yaml`: add `owner:` + `root:` to each workspace; remove `cwd:`.
5. Create `users.yaml` with linyilun + yaoshengyue + their feishu ids.
6. Restart esrd.

Migration script optional (small enough to do by hand for 2 envs × N workspaces).

## Next step

Spec v3 locked. Run `superpowers:code-reviewer` subagent for fact-check pass; address any findings; then open PR-20.
