# Session-first default resolution — design

**Date:** 2026-05-08
**Status:** spec rev-1 (user-approved framing 2026-05-07; awaiting rev-1 review)
**Companion file:** [`2026-05-08-session-first-default-resolution.zh_cn.md`](2026-05-08-session-first-default-resolution.zh_cn.md)
**Driving audit:** [`docs/manual-checks/2026-05-08-post-multi-instance-audit.md`](../../manual-checks/2026-05-08-post-multi-instance-audit.md) §3 mental-model gap + step 9
**Related:** [`docs/notes/concepts.md`](../../notes/concepts.md) tetrad metamodel; [`docs/futures/todo.md`](../../futures/todo.md) "Migrate to session-first model"

## 一、Goal

Operators (Feishu / CLI) describe their work in **session terms**, not workspace terms. After this spec lands, the audit's step 9 path

```
/session:new                          # no prior workspace setup needed
/workspace:add-folder path=/foo       # name= defaults to chat-current
/session:add-agent type=cc name=alice
```

**works without ever typing a workspace name** in the simple-user single-workspace case, and **stays explicit** for multi-workspace power users.

## 二、Non-goals

- Delete the `Esr.Resource.Workspace.*` resource layer. Workspaces stay as a first-class Resource per the tetrad metamodel.
- Remove `/workspace:*` slashes. They remain for explicit registry management.
- Per-session view mutation (`/session:add-folder` that mutates the running scope's view independent of its workspace). Out of scope; tracked separately.
- Plugin install-by-name registry. Tracked in `docs/futures/todo.md`.
- Session-first migration of every slash. The minimum sufficient change is the `resolve_workspace` fallback chain + `/user:use` + add-folder name fallback.

## 三、Locked design decisions (Feishu, 2026-05-07)

| ID | Decision | Source |
|---|---|---|
| D1 | Replace system `default` workspace with **per-user default** | "user default workspace 替代 system default … 可行" |
| D2 | New fallback chain: explicit arg → chat-default → user-default → error | "fallback chain（新）chat → user → error" |
| D3 | `Esr.Commands.User.Add` auto-creates `<username>-default` workspace + sets as user-default | "P2 选 a — auto-create" |
| D4 | `Esr.Resource.Workspace.Bootstrap` no longer creates a workspace named `default`. Bootstrap user gets `<bootstrap_user>-default` instead | "Bootstrap 路径改造" |
| D5 | `/workspace:add-folder name=` falls back to chat-current bound workspace when omitted | "C+: add-folder name= 默认 chat-current" |
| D6 | Existing on-disk `default` workspace state: **deleted** (no migration). Operators wipe via `tools/wipe-esrd-home.sh`. Approved 2026-05-07: "目前从未部署使用，请帮我删除清空" | Live wipe of `~/.esrd` + `~/.esrd-dev` performed 2026-05-08 |

## 四、Architecture

### 4.1 Metamodel alignment

`docs/notes/concepts.md` tetrad: Scope is a runtime instance of a Session; Resource (e.g. workspace) is referenced by Scope's membership. There is no concept of a "default Resource" at the metamodel level — every fallback is operational UX.

This spec's rule: **fallback prefers the most specific binding the system has on hand**. Specificity ladder:

```
explicit arg     ← operator typed it
chat-default     ← /workspace:use fixed it for this chat
user-default     ← /user:use fixed it for this user
(no fallback)    ← error: no_workspace_resolvable
```

Removing the system layer aligns with the metamodel: "default" is not a property of the system, it is a property of an Entity (user) or Scope (chat).

### 4.2 New primitive: User → default workspace mapping

Add to `Esr.Entity.User.Registry` (struct already has `:username` + `:feishu_ids`; we add `:default_workspace_id`):

```elixir
# user.json schema add:
#
#   {
#     "username": "linyilun",
#     "feishu_ids": ["ou_xxx"],
#     "default_workspace_id": "<uuid>"     // NEW
#   }

@spec set_default_workspace(username :: String.t(), ws_id :: String.t()) ::
        :ok | {:error, :not_found | :workspace_gone}

@spec get_default_workspace(username :: String.t()) ::
        {:ok, ws_id :: String.t()} | :not_found
```

ETS-backed (mirror of how `ChatScope.Registry.get/set_default_workspace` works today). Persisted to `Esr.Paths.user_json(user_uuid)` — pre-existing helper at `runtime/lib/esr/paths.ex:69-70`.

**Storage layout already half-designed:** `runtime/lib/esr/paths.ex:60-74` literally already documents
- `users_dir/0` as "Top-level dir for user-default workspaces"
- `user_workspace_json/1` as "Path to workspace.json for the user-default workspace"

The metamodel-aligned-esr migration (Phases 1-1b) carved out this storage slot but never wired the `default_workspace_id` field through `User.Registry`. This spec finishes that wiring. No new directory layout is invented.

### 4.3 New slash: `/user:use workspace=<name>`

Symmetric to `/workspace:use`. Sets the submitting user's default workspace. Translates `name` → workspace_id via `Workspace.NameIndex` and writes to `User.Registry`.

```yaml
"/user:use":
  kind: user_use
  permission: "workspace.create"
  command_module: "Esr.Commands.User.Use"
  requires_workspace_binding: false
  requires_user_binding: true
  category: "Users"
  description: "设当前 user 的 default workspace（per-user 偏好；/session:new fallback 链中 user-default 这一层）"
  args:
    - { name: workspace, required: true }
```

### 4.4 `Esr.Commands.User.Add` auto-creates user-default workspace

Today: `/user:add <username>` writes to `users.yaml` only.

After: same write, **plus** create a workspace named `<username>-default` (owned by the new user, location `{:esr_bound, <esrd>/default/workspaces/<username>-default}`), and set it as the new user's `default_workspace_id`. Single transaction; rollback on partial failure.

```elixir
# Pseudo-code (Esr.Commands.User.Add)
with :ok          <- write_user_yaml(name, args),
     {:ok, ws_id} <- create_user_default_workspace(name),
     :ok          <- User.Registry.set_default_workspace(name, ws_id) do
  {:ok, %{
    "action"               => "added",
    "username"             => name,
    "default_workspace_id" => ws_id,
    "default_workspace"    => "#{name}-default"
  }}
end
```

### 4.5 `Esr.Resource.Workspace.Bootstrap` rewrite

Today (`runtime/lib/esr/resource/workspace/bootstrap.ex`): creates a workspace named literally `default` if it doesn't exist.

After:

1. Read `ESR_BOOTSTRAP_PRINCIPAL_ID` (existing env)
2. Resolve the principal_id to a user via `Esr.Entity.User.Registry` (it must already exist via the env-driven bootstrap path; if not, exit early — let `/user:add` handle it)
3. If that user has no default workspace yet: create `<bootstrap_user>-default` and set it as their default

The literal name `default` is no longer reserved. If an operator wants a workspace named `default`, they can `/workspace:new name=default` and it's just a regular workspace.

### 4.6 `Esr.Commands.Scope.New.resolve_workspace` rewrite

Today's chain (per `runtime/lib/esr/commands/scope/new.ex:325-339`):

```
1. explicit args["workspace"]
2. chat-default via ChatScope.Registry.get_default_workspace
3. workspace_exists?("default") → fallback "default"
4. :no_match
```

After:

```
1. explicit args["workspace"]
2. chat-default via ChatScope.Registry.get_default_workspace
3. user-default via User.Registry.get_default_workspace
4. :no_match → error: no_workspace_resolvable
```

Tag tuples become `{:explicit, name}`, `{:chat_default, name}`, `{:user_default, name}`, `:no_match`.

The error message for step 4 changes:

```
no_workspace_resolvable:
  workspace not specified, no chat-default set, and submitter has no
  user-default. Run `/user:use workspace=<name>` to set one, or
  pass `workspace=<name>` explicitly.
```

### 4.7 `/workspace:add-folder name=` fallback

Today (`runtime/lib/esr/commands/workspace/add_folder.ex:29-30`): `name` is required.

After: `name` becomes optional. Resolution:

1. `args["name"]` if provided
2. else: `ChatScope.Registry.get_default_workspace(chat_id, app_id)` → workspace name
3. else: `User.Registry.get_default_workspace(submitting_user)` → workspace name
4. else: `{:error, %{"type" => "no_workspace_target"}}`

This re-uses the same chain as Scope.New, surfaced as a small private helper `Esr.Commands.Workspace.Resolve.workspace_for_args/1` to keep both call sites consistent.

## 五、Data flow examples

### 5.1 First-time operator (single user, single chat)

```
admin sets ESR_BOOTSTRAP_PRINCIPAL_ID=ou_alice (env)
esrd start
   → Capability.Supervisor seeds capabilities.yaml with admin grant for ou_alice
   → Workspace.Bootstrap waits — alice not in users.yaml yet
   → no system "default" workspace created (Δ from today)

alice opens Feishu, /user:add alice in DM
   → User.Registry.put({alice, [ou_alice]})
   → User.Add auto-creates "alice-default" workspace (owner=alice)
   → User.Registry.set_default_workspace("alice", ws_id)

alice: /session:new
   → resolve chain: no explicit, no chat-default, user-default = alice-default
   → spawns scope rooted at alice-default workspace

alice: /session:add-agent type=cc name=helper
   → spawns (CC, PTY) under per-session AgentSupervisor (M-2.6)
```

3 steps. No workspace creation required by the operator.

### 5.2 Multi-workspace operator

```
alice has alice-default + esr-dev + kanban (created via /workspace:new)

alice in chat A: /workspace:use workspace=esr-dev
   → ChatScope.Registry sets chat A → esr-dev

alice in chat A: /session:new
   → resolve: no explicit, chat-default = esr-dev, win
   → spawns scope on esr-dev

alice in chat B: /session:new
   → resolve: no explicit, no chat-default, user-default = alice-default, win
   → spawns scope on alice-default (cross-chat consistency)
```

### 5.3 Multi-user shared chat

```
chat C is bound to alice-default via /workspace:use (alice ran it)
bob arrives in chat C: /session:new
   → submitting_user = bob
   → resolve: no explicit, chat-default = alice-default — wait, that's alice's workspace
```

**Open question (P3 — needs decision):** in a multi-user chat, does chat-default override user-default? Two stances:

- **Stance A — chat-default wins (current spec rev-1):** simpler; matches today's per-chat semantics. bob runs sessions in alice's workspace, requires alice's grant on `workspace:alice-default/session:create`.
- **Stance B — user-default wins (alternative):** each user always gets their own workspace. bob's session runs in bob-default. Multi-user chat becomes "everyone in their own scope, sharing a chat". Diverges from today's chat-centric model.

**Spec rev-1 picks Stance A** because it matches the existing chat-default semantics and avoids surprising bob with a new workspace creation. Reconsider in a future spec if multi-user shared chats hit friction.

## 六、Migration

Per D6: existing `~/.esrd*/default/workspaces/default/workspace.json` and any old state was wiped on 2026-05-08 (live env, both prod + dev instances). Production note: any future deployment running this code wipes their existing `default` workspace via `tools/wipe-esrd-home.sh` before first boot. The wipe script's docstring already covers this.

`tools/wipe-esrd-home.sh` is updated to mention that this spec also bumped the bootstrap behavior (no-op rename — the script doesn't care, it deletes everything).

## 七、Test matrix

Add or modify (LOC estimate per file):

| File | What | LOC |
|---|---|---:|
| `runtime/test/esr/entity/user/registry_test.exs` | new `set/get_default_workspace` tests | +60 |
| `runtime/test/esr/commands/user/add_test.exs` | assert auto-created workspace + user-default link | +40 |
| `runtime/test/esr/commands/user/use_test.exs` (new) | `/user:use` happy + error paths | +80 |
| `runtime/test/esr/commands/scope/new_resolve_workspace_test.exs` | rewrite fallback chain tests; add user-default branch | +60 |
| `runtime/test/esr/commands/workspace/add_folder_test.exs` | new test for chain fallback when `name` omitted | +40 |
| `runtime/test/esr/resource/workspace/bootstrap_test.exs` (new or replace) | bootstrap creates `<user>-default`, not `default` | +60 |
| `runtime/test/esr/application_first_boot_test.exs` | drop assertions on system "default" name | -20 |

E2E scenario 19 (new): full first-time-operator path proving the audit step 9 sequence works without a workspace name.

## 八、Slash schema deltas

| Slash | Change |
|---|---|
| `/user:use` | NEW — args: `workspace` (required) |
| `/workspace:add-folder` | `name` becomes **optional**; falls back to chat-current → user-default |
| `/session:new` | Same shape; `resolve_workspace` impl swaps system "default" branch for user-default branch |
| `/user:add` | Result map gains `"default_workspace_id"` + `"default_workspace"` keys |

## 九、Invariant gates

After this spec lands:

1. `grep -rn '"default"' runtime/lib/esr/resource/workspace/bootstrap.ex` returns zero literal name matches; the bootstrap user's workspace name is computed from the user.
2. `Esr.Commands.Scope.New.resolve_workspace/1` no longer references the literal string `"default"` (verified by AST search).
3. New e2e scenario: fresh-install + `user:add` + `session:new` + `add-agent` succeeds without any `/workspace:*` invocation.
4. Multi-chat consistency test: same user runs `/session:new` in two different chats with no chat-default set → both bind to user-default.
5. `User.Registry.set_default_workspace(user, ws_id)` is rolled back if subsequent step fails (atomic combined transaction in `Esr.Commands.User.Add`).

## 十、Out-of-scope follow-ups (separate specs)

- `/session:add-folder` mutating the running scope's workspace view (audit step 9 second-half ambition).
- `/user:use` accepting `name` resolved cross-instance.
- Multi-tenant fallback (admin acting on behalf of another user — needs cap design).
- Stance B from §5.3 (user-default wins over chat-default in shared chats).

## 十一、Estimated LOC

| Area | LOC |
|---|---:|
| Lib (User.Registry + User.Use + Bootstrap rewrite + resolve_workspace + add-folder fallback + Scope.New error msg) | ~250 |
| Tests (per matrix) | ~280 |
| E2E scenario 19 | ~120 |
| Docs (this spec + zh_cn + manual-checks update + futures/todo.md update + slash-routes.default.yaml) | ~150 |
| **Total** | **~800 LOC** |

Within reach of a single PR, target net deletion (remove system "default" branch + simplify) ~20 LOC, net add ~780 LOC.
