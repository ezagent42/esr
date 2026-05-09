# Feishu self-bind via `/feishu:bind` + `/feishu:unbind`

**Spec id:** 2026-05-09-feishu-slash-bind
**Author:** Allen Woods + Claude
**Status:** rev-1 (brainstorm 2026-05-09)
**Tracks:** Feishu plugin slash surface — adds operator self-service path

## 1. Problem statement

Today, binding a Feishu `open_id` (`ou_xxx`) to an esr user is **CLI-only**:

```bash
esr-dev exec feishu_bind --name=linyilun --feishu_user_id=ou_6b11faf8e93aedfb9d3857b9cc23b9e7
```

The Feishu plugin's manifest (`runtime/lib/esr/plugins/feishu/manifest.yaml:71`) has no slash routes — `slashes: {}`. So a Feishu user wanting to register themselves cannot do it from inside Feishu; an operator with `feishu/user-bind` cap must do it on their behalf via the admin queue.

This raises the operator's onboarding cost and breaks the "register from where you live" mental model: every other principal action (sessions, workspaces, agents) is reachable as a slash from the chat surface; `bind` is the only mandatory step that isn't.

This spec adds **self-service** versions:
- `/feishu:bind name=<n>` — bind the caller's Feishu account to esr user `<n>`.
- `/feishu:unbind` — unbind the caller's Feishu account from whichever esr user it is currently bound to.

Admin-代-bind (binding *another* user's `ou_xxx` for them) stays on the existing CLI / admin-queue path with `feishu/user-bind` cap. The CLI surface and `BindUser` / `UnbindUser` modules do not change.

## 2. Non-goals

- **Not** changing admin path. `esr-dev exec feishu_bind ...` keeps its current contract and `feishu/user-bind` cap.
- **Not** auto-creating esr users. `name=` must already exist in `users.yaml` (admin runs `user_add` first); `bind_user.ex:31-35` already enforces this.
- **Not** issuing claim tokens or per-`ou_xxx` pre-grant caps. Self-bind is gated by chat membership (operator put the user in a chat with the Feishu bot).
- **Not** supporting unbind-by-name for someone else. `/feishu:unbind` only operates on the caller's own `ou_xxx`. Cross-account unbind stays admin CLI.
- **Not** adding an e2e shell scenario. The new logic is BEAM-local (no cross-process / cross-platform interaction). Unit + registry tests cover the surface.

## 3. Design

### 3.1 Files

| File | Action | LOC |
|---|---|---|
| `runtime/lib/esr/plugins/feishu/commands/self_bind.ex` | new | ~20 |
| `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex` | new | ~30 |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | edit `slash_routes:` | +18 |
| `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs` | new | ~120 |
| `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs` | new | ~100 |
| `runtime/test/esr/plugins/feishu/commands/migration_test.exs` | edit (4 new asserts) | +20 |

Untouched: `bind_user.ex`, `unbind_user.ex`, core `slash_handler.ex`, `slash-routes.default.yaml`, FAA / FAP / FCP, e2e scenarios.

### 3.2 Plugin manifest diff

`runtime/lib/esr/plugins/feishu/manifest.yaml`, `slash_routes:` block:

```yaml
slash_routes:
  schema_version: 1
  slashes:
    "/feishu:bind":
      kind: feishu_self_bind
      permission: null
      command_module: "Esr.Plugins.Feishu.Commands.SelfBind"
      requires_workspace_binding: false
      requires_user_binding: false
      category: "Users"
      description: "把当前 Feishu 账号绑到一个 esr user (admin 须先创建该 user)"
      args:
        - { name: name, required: true }

    "/feishu:unbind":
      kind: feishu_self_unbind
      permission: null
      command_module: "Esr.Plugins.Feishu.Commands.SelfUnbind"
      requires_workspace_binding: false
      requires_user_binding: false
      category: "Users"
      description: "把当前 Feishu 账号从绑定的 esr user 上解绑"
      args: []

  internal_kinds:
    feishu_notify: ...                       # unchanged
    feishu_bind: ...                         # unchanged (admin-代-bind)
    feishu_unbind: ...                       # unchanged (admin-代-unbind)
    feishu_self_bind:                        # new — must mirror slash kind
      permission: null
      command_module: "Esr.Plugins.Feishu.Commands.SelfBind"
    feishu_self_unbind:                      # new
      permission: null
      command_module: "Esr.Plugins.Feishu.Commands.SelfUnbind"
```

The slash entry and the `internal_kinds` entry must agree on `permission` and `command_module` — `slash-routes.default.yaml:765-767` warns this is a known footgun (registry rebuild silently drops mismatched entries; covered by `registry_test.exs:533` regression).

### 3.3 Kind taxonomy

| kind | submitter | command | permission | role |
|---|---|---|---|---|
| `feishu_bind` | CLI / admin queue | `BindUser` | `feishu/user-bind` | admin-代-bind (must pass `feishu_user_id=`) |
| `feishu_self_bind` | `/feishu:bind` slash | `SelfBind` | null | self-bind (envelope `ou_xxx`) |
| `feishu_unbind` | CLI / admin queue | `UnbindUser` | `feishu/user-bind` | admin-代-unbind |
| `feishu_self_unbind` | `/feishu:unbind` slash | `SelfUnbind` | null | self-unbind |

### 3.4 Permission model

`permission: null` — chat-membership trust. Justification:

1. `bind_user.ex:31-35` already requires `name=` to exist in `users.yaml`. An operator must run `user_add name=<n>` ahead of time, which keeps the **principal namespace** under admin control. The slash only lets the user themselves complete the second step ("attach my `ou_xxx` to my pre-created username").
2. The slash is reachable only from inside a Feishu chat that has a Feishu bot configured for this esrd. Bot membership is operator-controlled.
3. First-claim-wins is **safe-ish** because of the chat-membership filter: if a malicious chat member tries to claim `name=linyilun` before the real linyilun, both must be in the same Feishu chat with the bot — already a high trust boundary.

Pure-`ou_xxx`-keyed caps are not used: the codebase is moving to username-keyed caps (`bind_user.ex` moduledoc), and self-bind by definition has no username yet.

### 3.5 SlashHandler integration (no changes)

`Esr.Entity.SlashHandler.inject_envelope_args/2` (`slash_handler.ex:662-673`) already injects `principal_id` into args from `envelope["principal_id"] || envelope["user_id"]`. SelfBind / SelfUnbind read `args["principal_id"]` directly. **Core SlashHandler is not modified** — this avoids the per-plugin lobbying anti-pattern that `merge_chat_context(args, "session_new", _)` already represents.

## 4. Data flow

### 4.1 `/feishu:bind name=linyilun`

```
Feishu user types: /feishu:bind name=linyilun
        │
        ▼
FeishuChatProxy → envelope:
  envelope = %{
    "principal_id" => "ou_6b11faf8...",
    "user_id"      => "ou_6b11faf8...",
    "payload" => %{"text" => "/feishu:bind name=linyilun",
                   "args" => %{"app_id" => "cli_xxx"}},
    ...
  }
        │
        ▼
SlashHandler.dispatch(envelope, reply_to)            (slash_handler.ex:113)
  · extract_text → "/feishu:bind name=linyilun"
  · resolve route → kind=feishu_self_bind, permission=null (skip cap check)
  · inject_envelope_args/2 → args = %{
      "name" => "linyilun",
      "principal_id" => "ou_6b11faf8...",  ← injected
      "chat_id" => "...", "app_id" => "..."
    }
  · dispatch → SelfBind.execute(%{"args" => args})
        ▼
Esr.Plugins.Feishu.Commands.SelfBind.execute/1       (NEW)
  · pattern-match {name, principal_id} both non-empty binary
  · args2 = Map.put(args, "feishu_user_id", principal_id)   ← envelope wins
  · BindUser.execute(%{"args" => args2})
        ▼
Esr.Plugins.Feishu.Commands.BindUser.execute/1       (existing, bind_user.ex:23)
  · user_not_found?    → :error
  · already_bound_to?  → :ok (idempotent)
  · bound_to_other?    → :error feishu_id_in_use
  · else: append_id + Yaml.Writer.write
        ▼
{:ok, %{"text" => "bound ou_6b11... to esr user linyilun"}}
        ▼
SlashHandler → reply_to → FeishuChatProxy → group reply
```

### 4.2 `/feishu:unbind`

```
SelfUnbind.execute/1                                  (NEW)
  · principal_id from args (envelope-injected)
  · scan users.yaml, find entry where ou_xxx ∈ feishu_ids
    · not found → {:ok, "ou_xxx not bound to any esr user"}  (idempotent)
    · found in users[Y] → delegate to UnbindUser.execute(%{
        "args" => %{"name" => Y, "feishu_user_id" => principal_id}
      })
  · UnbindUser writes yaml, returns {:ok, "unbound ... from Y"}
```

`SelfUnbind` does the lookup + delegates so the actual yaml mutation lives in one place (`UnbindUser`). The lookup is `Enum.find_value(users, fn {n, row} -> if fid in (row["feishu_ids"] || []), do: n end)`.

### 4.3 SelfBind module (full pseudocode)

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfBind do
  @moduledoc """
  Slash-only self-bind wrapper for `/feishu:bind`. Reads the caller's
  Feishu open_id from the envelope-injected `args["principal_id"]`,
  delegates to BindUser. Any caller-supplied `feishu_user_id=` is
  silently overwritten — envelope is the single source of truth for
  identity. Admin-代-bind takes the BindUser path directly via the
  `feishu_bind` internal_kind (CLI submit, gated by `feishu/user-bind`).
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.BindUser

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"name" => name, "principal_id" => p} = args})
      when is_binary(name) and name != "" and is_binary(p) and p != "" do
    args = Map.put(args, "feishu_user_id", p)
    BindUser.execute(%{"args" => args})
  end

  def execute(_) do
    {:error, %{
      "type" => "invalid_args",
      "message" =>
        "/feishu:bind needs args.name; caller ou_xxx is auto-injected from the envelope"
    }}
  end
end
```

### 4.4 SelfUnbind module (full pseudocode)

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfUnbind do
  @moduledoc """
  Slash-only self-unbind wrapper for `/feishu:unbind`. Looks up which
  esr user currently owns the caller's `ou_xxx` and delegates to
  UnbindUser. Idempotent if the caller has no binding.
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.UnbindUser

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"principal_id" => p}}) when is_binary(p) and p != "" do
    case lookup_owner(p) do
      nil ->
        {:ok, %{"text" => "#{p} is not bound to any esr user"}}

      name ->
        UnbindUser.execute(%{"args" => %{"name" => name, "feishu_user_id" => p}})
    end
  end

  def execute(_) do
    {:error, %{
      "type" => "invalid_args",
      "message" => "/feishu:unbind requires an envelope-injected principal_id"
    }}
  end

  defp lookup_owner(fid) do
    path = Esr.Paths.users_yaml()

    case YamlElixir.read_from_file(path) do
      {:ok, %{"users" => users}} when is_map(users) ->
        Enum.find_value(users, fn {name, row} ->
          if is_map(row) and fid in (Map.get(row, "feishu_ids") || []), do: name
        end)

      _ -> nil
    end
  end
end
```

## 5. Error semantics

### 5.1 `/feishu:bind name=X`

| Input | Behavior | error type |
|---|---|---|
| missing `name=` or envelope lacks `ou_xxx` | error | `invalid_args` |
| `name=X` does not exist | error | `user_not_found` (existing) |
| caller `ou_xxx` already in `users[X].feishu_ids` | idempotent ok | — |
| caller `ou_xxx` in `users[Y].feishu_ids`, Y ≠ X | error (suggest `/feishu:unbind` first) | `feishu_id_in_use` (existing) |
| `users[X]` exists, has other `ou_xxx`s already | append (multi-device) | ok |
| yaml write fails | error | `write_failed` (existing) |

Caller-supplied `feishu_user_id=` is **silently overwritten** by the envelope's `principal_id`. The attack-injection path (someone passing `feishu_user_id=ou_VICTIM`) is closed because `Map.put` always wins over user input. We do not raise an error for the redundant arg — it is harmless after overwrite, and a unit test asserts the overwrite property (§ 6.1 case 8).

`feishu_id_in_use` message text is improved from the existing form to include the actionable next step:

```
feishu_id ou_xxx is already bound to esr user 'Y'; run /feishu:unbind first, then /feishu:bind name=X
```

### 5.2 `/feishu:unbind`

| Input | Behavior | error type |
|---|---|---|
| envelope lacks `ou_xxx` | error | `invalid_args` |
| caller `ou_xxx` not in any `users[*].feishu_ids` | idempotent ok | — |
| caller `ou_xxx` in `users[Y].feishu_ids` | unbind, reply `unbound from <Y>` | — |
| yaml write fails | error | `write_failed` (existing in UnbindUser) |

## 6. Test plan

### 6.1 `self_bind_test.exs` (unit, 8 cases, `async: false`)

Each test sets up `ESRD_HOME` tmp + a `users.yaml` fixture, calls `SelfBind.execute/1` directly, asserts result + on-disk yaml.

| # | Case | Expected |
|---|---|---|
| 1 | golden — `users[linyilun]` exists with `feishu_ids: []`, call with `principal_id=ou_X` | `:ok`, yaml gains `[ou_X]` |
| 2 | idempotent — `users[linyilun].feishu_ids: [ou_X]`, call again | `:ok`, yaml unchanged |
| 3 | multi-bind append — `users[linyilun].feishu_ids: [ou_OTHER]`, call `principal_id=ou_X` | `:ok`, yaml = `[ou_OTHER, ou_X]` |
| 4 | conflict — `users[bob].feishu_ids: [ou_X]`, call `name=linyilun principal_id=ou_X` | `{:error, %{"type" => "feishu_id_in_use"}}` |
| 5 | user_not_found — `name=ghost` not in users.yaml | `{:error, %{"type" => "user_not_found"}}` |
| 6 | invalid — missing `name=` | `{:error, %{"type" => "invalid_args"}}` |
| 7 | invalid — missing `principal_id=` (envelope-anomaly fallback) | `{:error, %{"type" => "invalid_args"}}` |
| 8 | silent overwrite — args carry both `principal_id=ou_X` and `feishu_user_id=ou_VICTIM` | `:ok`, yaml gains `ou_X` (NOT `ou_VICTIM`) — closes attack-injection path |

### 6.2 `self_unbind_test.exs` (unit, 6 cases, `async: false`)

| # | Case | Expected |
|---|---|---|
| 1 | golden — `users[linyilun].feishu_ids: [ou_X]`, call `principal_id=ou_X` | `:ok`, reply contains `unbound`, `from linyilun`; yaml = `[]` |
| 2 | idempotent — `ou_X` not in any user | `:ok`, reply contains `not bound`; yaml unchanged |
| 3 | partial removal — `users[linyilun].feishu_ids: [ou_X, ou_Y]`, call `principal_id=ou_X` | `:ok`, yaml = `[ou_Y]` |
| 4 | invalid — missing `principal_id=` | `{:error, %{"type" => "invalid_args"}}` |
| 5 | silent overwrite — args carry `principal_id=ou_X` and `feishu_user_id=ou_OTHER` | `:ok`, unbinds `ou_X` (not `ou_OTHER`) |
| 6 | yaml write fails — make `users.yaml` parent dir read-only | `{:error, %{"type" => "write_failed"}}` |

### 6.3 `migration_test.exs` extension (registry, 4 new asserts)

Append to existing file:

```elixir
test "kind: feishu_self_bind resolves to SelfBind" do
  assert Esr.Plugins.Feishu.Commands.SelfBind ==
           SlashRouteRegistry.command_module_for("feishu_self_bind")
end

test "kind: feishu_self_unbind resolves to SelfUnbind" do
  assert Esr.Plugins.Feishu.Commands.SelfUnbind ==
           SlashRouteRegistry.command_module_for("feishu_self_unbind")
end

test "slash /feishu:bind routes to SelfBind via plugin manifest" do
  assert {:ok, %{kind: "feishu_self_bind", command_module: Esr.Plugins.Feishu.Commands.SelfBind}} =
           SlashRouteRegistry.lookup("/feishu:bind")
end

test "slash /feishu:unbind routes to SelfUnbind via plugin manifest" do
  assert {:ok, %{kind: "feishu_self_unbind", command_module: Esr.Plugins.Feishu.Commands.SelfUnbind}} =
           SlashRouteRegistry.lookup("/feishu:unbind")
end
```

### 6.4 What is not tested

- **Not** SlashHandler envelope injection — `inject_envelope_args/2` is covered by SlashHandlerTest.
- **Not** FeishuChatProxy → SlashHandler routing — `feishu_chat_proxy_routing_test.exs` covers it.
- **Not** "permission: null lets unauthenticated through" — that is SlashHandler's contract, not the plugin's.
- **No** e2e shell scenario — pure BEAM-local logic, unit + registry suffice.

### 6.5 Test stability constraints

- `async: false` because tests share `ESRD_HOME` env + `users.yaml`. Switching to `async: true` would race-fail intermittently when adjacent tests touch the same file.
- No FSEvents / fs-watcher dependence — `SelfBind.execute/1` is called directly. The macOS FSEvents flake documented in CLAUDE.md gotcha #2 does not apply.
- `Esr.Yaml.Writer` atomic-write semantics covered by `runtime/test/esr/yaml_writer_test.exs`.

## 7. Risk + open questions

### 7.1 Race: admin races user

Scenario: admin runs `user_add name=linyilun` ahead of real linyilun showing up; an attacker in the same chat types `/feishu:bind name=linyilun` first and grabs the binding.

Mitigation: chat-membership trust + admin operational discipline. Documented in § 3.4. If this becomes a real attack vector, follow-up spec adds claim-token mechanism (see § 8).

### 7.2 `users.yaml` non-atomic read in `SelfUnbind`

`lookup_owner/1` and `UnbindUser.execute/1` each read `users.yaml` independently. A concurrent admin-代-unbind could complete between the two reads, making the second read see no entry — `UnbindUser` then errors `user_not_found` even though `lookup_owner` saw it. Acceptable: low probability, idempotent retry recovers, error message is clear ("re-run /feishu:unbind").

### 7.3 Open question: telemetry

Should self-bind / self-unbind emit a telemetry event (e.g., `[:esr, :slash, :feishu, :self_bind]`) for audit logging? **Default: no** for rev-1 (no other slash emits self-event telemetry). Revisit if abuse incidents surface.

## 8. Future work (out of scope)

- **Claim-token gating.** If chat-membership trust proves insufficient, `user_add` could optionally generate a single-use, time-bound token printed once, given to the user out-of-band. `/feishu:bind name=X token=<T>` would gate the bind. Adds ~150 LOC + token storage; deferred until needed.
- **Symmetric Telegram self-bind.** When Telegram plugin matures, mirror this design: `/telegram:bind` in the telegram plugin's manifest. The pattern (envelope-only, silent overwrite, delegate to existing admin command) is platform-agnostic.
- **Telemetry / audit log.** § 7.3.

## 9. Summary of decisions

1. New slash names: `/feishu:bind`, `/feishu:unbind` — plugin-owned, registered in feishu manifest. Symmetric for future `/telegram:bind` etc.
2. Permission: `null` (chat-membership trust). Justified by pre-existing `user_add` admin gate + bot-membership operator control.
3. Bundle bind + unbind in same spec — operationally inseparable (re-bind requires unbind first).
4. Bind conflict: error with actionable hint, no silent rebind, no `force=` flag.
5. Implementation: thin wrapper modules (`SelfBind`, `SelfUnbind`) delegating to existing `BindUser` / `UnbindUser`. Core SlashHandler not modified.
6. Caller-supplied `feishu_user_id=` is silently overwritten by envelope `principal_id`. Test asserts the overwrite property.
7. `/feishu:unbind` takes no args — always operates on caller's `ou_xxx`. Unbind-by-name stays admin CLI.
