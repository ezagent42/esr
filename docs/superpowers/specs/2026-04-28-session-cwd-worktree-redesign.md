# PR-20 Spec: Session cwd + tag/worktree redesign

**Status:** brainstorm v2 — restructured after user's 2026-04-28 08:31 clarification.
**Author:** allen (linyilun) + claude pair-prog session.
**Date:** 2026-04-28.
**Implementation PR:** PR-20 (after this spec is locked).

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

## Locked decisions (from user clarification)

| # | Decision | Source |
|---|---|---|
| **D1** | No backwards compatibility shim. esrd has 0 live sessions today; PR-20 is a clean break. | 2026-04-28 08:31 #1 |
| **D2** | `/new-session` takes **three explicit positional/keyword args**: `name`, `cwd`, `worktree`. No derivation from workspace. | 2026-04-28 08:31 #2 |
| **D3** | `name` = the session's identity. tmux session name, CC handle, log line prefix, `actors list` row — all key off this. | 2026-04-28 08:31 #2a |
| **D4** | `cwd` = where CC's process actually runs. Operator picks; esrd doesn't derive it. | 2026-04-28 08:31 #2b |
| **D5** | `worktree` = the **git branch name** of the worktree fork. Always forks from `main` initially; operator switches branches manually post-spawn if they want. | 2026-04-28 08:31 #2c |
| **D6** | One session per worktree. Forbidden to start a second session naming an existing worktree. | 2026-04-28 08:31 #2d |

## Proposed shape

```
workspace (template / persistent config — UNCHANGED scope)
├── name: esr-dev                          ← addressed by chat
├── chats: [{chat_id: oc_…, app_id: …}]    ← IM chats routing to it
├── role: dev                              ← CC's CLAUDE.md prelude
├── start_cmd: scripts/esr-cc.sh           ← how to spawn CC
└── (workspace.cwd field deleted — D1, D4)

slash command shape (per D2):
  /new-session esr-dev name=root cwd=/Users/h2oslabs/Workspace/esr-feature-foo worktree=feature-foo

session (concrete instance, in-memory + sessions.yaml)
├── workspace: esr-dev
├── name: root                             ← D3; tmux session = "esr_cc_root"
├── cwd: /Users/h2oslabs/Workspace/esr-feature-foo
└── worktree_branch: feature-foo           ← D5; created via `git worktree add`
```

The runtime, on `/new-session`:
1. Validates `name` doesn't collide with another live session under the same workspace (D6 lite — a stricter version of D6 sits below in Q-collision).
2. If `worktree` is given AND `cwd` doesn't already exist:
   `git -C <some_repo_root> worktree add <cwd> -b <worktree> main`.
3. Spawns CC's tmux pane with that `cwd` and tmux session name `esr_<name>` (or similar — see Q-tmux-name).

## Open mechanics — 5 narrower questions

D1-D6 lock the high-level shape. Five mechanics still open:

---

### Q-collision: collision rules — name, cwd, worktree

D6 says "one session per worktree". What about `name` and `cwd`?

**(a) `worktree` is the unique key.** Two sessions with same `name`
or same `cwd` are allowed; only `worktree` collisions are rejected.
Risk: two `name=root` sessions break tmux session naming
(`esr_cc_root` collides).

**(b) All three (`name`, `cwd`, `worktree`) must be unique within an
esrd environment.** Belt-and-braces. Easy to explain, no edge cases.

**(c) `name` unique within workspace; `cwd` and `worktree` unique
globally.** Allows `name=root` in two different workspaces.

**Default recommendation: (b).** Simplest mental model; matches the
spirit of "each session is an isolated thing".

---

### Q-tmux-name: tmux session name from `name`

When operator types `name=root`, what's the tmux session called?

**(a) `esr_cc_root`.** Today's `esr_cc_<N>` integer pattern, with
`<N>` replaced by `name`. Backward-pattern-compatible.

**(b) `<workspace>_<name>`.** e.g. `esr-dev_root`. Disambiguates
across workspaces if Q-collision lands on (c).

**(c) `<name>`.** Just the operator's chosen name verbatim.
Shortest. Conflicts with system tmux sessions if user picks a
common name like `default`.

**Default recommendation: (a) `esr_cc_<name>`.** Keeps the existing
`esr_cc_*` namespace prefix so operators' grep / attach habits don't
break. Operator-provided name replaces the integer.

---

### Q-cwd-relation: relationship between `cwd` and `worktree`

Operator passes both `cwd=` and `worktree=`. The runtime needs to know:

**(a) `cwd` IS the worktree path.** The runtime runs
`git worktree add <cwd> -b <worktree>`. The operator's `cwd` is
where the new worktree gets created. Constraint: `cwd` must NOT
already exist (otherwise `git worktree add` fails). Cleanest mapping.

**(b) Operator pre-creates worktree, then names them both.** Operator
manually does `git worktree add /path/to/foo -b feature-foo main`,
THEN runs `/new-session esr-dev name=root cwd=/path/to/foo
worktree=feature-foo`. The runtime just records the binding without
running `git`. Pro: no git side-effects from a slash command.
Con: operator does extra work; slash-command UX worse.

**(c) `cwd` is the parent directory; runtime creates a subdir.** e.g.
`cwd=/Users/h2oslabs/Workspace/esr` + `worktree=feature-foo` →
runtime creates `/Users/h2oslabs/Workspace/esr/<somewhere>/feature-foo`.
Awkward — operator gave us `cwd`, we change it.

**(d) `worktree` is optional.** If absent, runtime treats `cwd` as a
plain working dir (no git interaction). If present, (a) applies.
This makes the user's "需要切换可以手动去切换" comment work
naturally — operator can spawn a session with just cwd, no
worktree management, and switch branches in-place.

**Default recommendation: (a) + (d) combined.** When `worktree=` is
given, runtime auto-creates worktree at `cwd`. When `worktree=` is
absent, runtime just uses `cwd` as-is and CC works in the existing
checkout. Operators get the choice.

---

### Q-which-repo: which git repo does `git worktree add` operate on?

When `/new-session` runs `git worktree add <cwd> -b <worktree>
main`, which directory is the "main" repo (the one whose `.git/`
directory sources the worktree)?

**(a) The workspace's existing main checkout.** workspaces.yaml gains
a `repo_root:` field (e.g. `/Users/h2oslabs/Workspace/esr`). Runtime
runs `git -C <repo_root> worktree add ...`.

**(b) Inferred from `cwd`'s parent / sibling.** If `cwd` is
`/Users/h2oslabs/Workspace/esr-feature-foo`, look for a `.git` in
sibling directories. Magic; brittle.

**(c) Operator passes it as a fourth arg.** `/new-session ws name=
cwd= worktree= repo=/path/to/main`. Most flexible, most typing.

**Default recommendation: (a) `repo_root:` on the workspace.** Each
workspace already has a long-lived "main checkout" implicit in the
operator's mental model; making it explicit in the workspace yaml
matches that.

---

### Q-end-cleanup: `/end-session` worktree cleanup

When session ends, what happens to the worktree on disk?

**(a) Always keep.** Operator manually `git worktree remove`. Safe;
disk fills.

**(b) Always prune (`git worktree remove --force`).** Auto-cleanup;
risk of losing uncommitted work.

**(c) Prune iff clean.** `git status --porcelain` empty → remove.
Dirty → keep + log warning.

**(d) Per-session flag.** `/end-session foo --keep-worktree` opts in
to retention. Default = (c).

**Default recommendation: (c) prune iff clean.** Auto-handles "tried
this branch, didn't work" case; protects in-progress work; no extra
flags needed.

---

## Out of scope (deferred)

- **Per-session role override**: today the workspace dictates `role:
  dev` or `role: diagnostic`; per-session override is a future PR.
- **Cross-workspace branch sharing**: highly speculative.
- **Worktree GC sweep**: periodic prune of branchless worktrees;
  operator can `git worktree prune` by hand.
- **`workspace add --repo-root` CLI**: depends on Q-which-repo; if
  recommendation lands, the CLI gets a new flag (small change, but
  let's land the runtime side first then the CLI).

## Implementation outline

Conditional on the 5 open Qs being answered:

1. **Workspace yaml schema** — delete `cwd:` field; add `repo_root:`
   (per Q-which-repo). Update `workspace add` CLI.
2. **`/new-session` parser** — accept `name=`, `cwd=`, `worktree=`;
   reject if any required ones are missing.
3. **Worktree spawn helper** — `git worktree add <cwd> -b <worktree>
   main` invoked via `System.cmd("git", ...)`. Error handling for
   already-exists / detached-head / etc.
4. **Session registry** — track `(workspace, name, worktree)`
   collision; reject duplicates per Q-collision answer.
5. **`/end-session` cleanup** — `git status --porcelain` check;
   conditional `git worktree remove`.
6. **tmux session naming** — `esr_cc_<name>` per Q-tmux-name.

LOC budget: ~200 Elixir runtime + ~50 Python CLI + ~15 doc/spec
update.

## Subagent-review checklist (run after user answers the 5 Qs)

`superpowers:code-reviewer` should fact-check:

- [ ] `git worktree add <path> -b <new_branch> main` works as
      expected on macOS git 2.40+ (specifically: does `main` need to
      be `origin/main` if local `main` is behind?).
- [ ] Existing `Esr.SessionRegistry` collision detection can be
      extended to enforce Q-collision rules without a major refactor.
- [ ] No existing test fixture relies on `tag=` being load-bearing in
      a way that the rename to `name=` / `worktree=` would silently
      break.
- [ ] The deny-DM / guide-DM rate limits in PR-N are keyed on
      `chat_id`, not `(chat_id, session_name)` — confirm renaming
      doesn't perturb them.
- [ ] `workspaces.yaml` `metadata:` (PR-F) and `neighbors:` (PR-C)
      survive the schema change unchanged.

## Next step

User answers the 5 open Qs. Then this doc gets a **Decisions:**
section per Q, code-reviewer subagent fact-checks, and PR-20 opens.
