# Feishu self-bind via `/feishu:bind` + `/feishu:unbind`

**Spec id:** 2026-05-09-feishu-slash-bind
**Author:** Allen Woods + Claude
**Status:** rev-1 (brainstorm 2026-05-09)
**Tracks:** Feishu plugin slash surface — adds operator self-service path

## 0. rev-3 changelog (2026-05-09 post subagent plan-review)

A subagent review of the implementation plan caught a real security gap that invalidated rev-2's "core SlashHandler not modified" claim:

- **R1 — `principal_id` user-overwrite gap** — `Esr.Entity.SlashHandler.inject_envelope_args/2` (`slash_handler.ex:662-673`) uses `maybe_put` (= `Map.put_new`) for `principal_id`. So a chat member typing `/feishu:bind name=linyilun principal_id=ou_VICTIM` would have args reach SelfBind with `principal_id=ou_VICTIM` (user value retained, envelope value discarded by `Map.put_new`). The whitelist (rev-2's defence) accepts `principal_id` because it IS an envelope-injected key, so the attack is NOT blocked.
  **Fix**: change the `principal_id` line in `inject_envelope_args/2` from `maybe_put` to `Map.put` (force-overwrite when envelope has a value). Other envelope-injected keys (`chat_id`, `app_id`, `thread_id`) keep `maybe_put` semantics — `/workspace:bind-chat` legitimately accepts user-supplied `chat_id=`.
  **Impact audit** (slash-callable consumers of `args["principal_id"]`): `Esr.Commands.Whoami`, `Esr.Commands.Doctor` use it for display only with `(unknown)` fallback — overwrite is correct. Other consumers (`cap/grant`, `cap/revoke`, `cap/show`, `session/share`, `cross_app_test`) are `internal_kinds` CLI-only and do not go through SlashHandler dispatch — unaffected. § 3.5 updated; § 4.3 / § 4.4 reaffirmed; new § 3.5.1 documents the SlashHandler change.

- **R2 — SelfUnbind race UX fix** — when `lookup_owner/1` finds the owning user but a concurrent admin `feishu_unbind` slips in before delegation, `UnbindUser` returns `user_not_found`, which is confusing for self-unbind ("the user isn't gone, the binding raced"). Catch `user_not_found` in `SelfUnbind` and remap to idempotent `{:ok, "no longer bound"}`. § 4.4 updated, test case added.

- **R3 — Test stability** — three plan-level tweaks: (a) idempotent test asserts on parsed yaml structure, not byte-string equality (`Esr.Yaml.Writer` re-emits sorted, would silently break on a future yaml-formatter change); (b) `chmod 0o555` write-fail test guarded by `:os.type/0 + EUID != 0` skip on root/CI; (c) plan adds an IEx pre-check on `Registry.lookup/1` return shape since current feishu manifest has `slashes: {}` (no other slash to verify atom-vs-string keys against).

- **R4 — `username` has the same vulnerability shape, deferred** — `merge_chat_context` (slash_handler.ex:705, 723) also uses `maybe_put("username", ...)`. Anyone typing `username=victim` against `/session:new` etc could spoof username. Out of scope for this spec — added to `docs/futures/todo.md` as separate audit work.

## 0. rev-2 changelog (2026-05-09 post user review)

User review pass on rev-1 yielded three structural changes:

- **U1** — caller-supplied `feishu_user_id=` is now **rejected as `invalid_args`**, not silently overwritten. Generalised to "any non-allowed key in `args` rejects". Implemented as a per-command `@allowed_keys` whitelist; SlashHandler unchanged. Test `case 8` reframed to assert the rejection; new `case 9` covers an arbitrary unknown key (`random_arg=`) to anchor the generic property.
- **U2** — telemetry events `[:esr, :slash, :feishu, :self_bind]` and `[:esr, :slash, :feishu, :self_unbind]` are emitted on every invocation. § 4.5 added; relevant test cases added.
- **U3** — `users.yaml` race in SelfUnbind (lookup + delegate, two reads) is documented as a comment marker on `lookup_owner/1` per § 7.2 disposition (acceptable, retry recovers). No code change to mitigate.

Minor:

- The "username-keyed cap migration accelerator" observation is moved into `docs/futures/todo.md` (`Pending — concrete next PRs` section) so it surfaces beyond this spec.

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
| `runtime/lib/esr/entity/slash_handler.ex` | edit (1 line: `principal_id` `maybe_put` → `Map.put`) | +1/-1 |
| `runtime/test/esr/entity/slash_handler_test.exs` | edit (1 new test for force-overwrite) | +25 |
| `runtime/lib/esr/plugins/feishu/commands/self_bind.ex` | new | ~50 (incl. whitelist + telemetry + helpers) |
| `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex` | new | ~70 (incl. whitelist + telemetry + lookup + race-remap) |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | edit `slash_routes:` | +18 |
| `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs` | new | ~180 (11 cases) |
| `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs` | new | ~160 (10 cases incl. race-remap) |
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

### 3.5 SlashHandler integration (one-line surgical change, rev-3)

**Original rev-1/rev-2 claim withdrawn.** A subagent plan-review caught that `Esr.Entity.SlashHandler.inject_envelope_args/2` (`slash_handler.ex:662-673`) uses `maybe_put` (= `Map.put_new`) for `principal_id`, which retains caller-supplied `principal_id=ou_VICTIM` over the envelope's value. Since this slash uses `permission: null`, anyone in the chat could exploit this to bind any `ou_xxx` to any pre-existing username — the rev-2 whitelist defence is bypassed because `principal_id` IS in the whitelist.

#### 3.5.1 The fix

Change one line in `inject_envelope_args/2`:

```elixir
# before (rev-1/rev-2):
args
|> maybe_put("chat_id", chat_id)
|> maybe_put("thread_id", thread_id)
|> maybe_put("app_id", app_id)
|> maybe_put("principal_id", principal_id)

# after (rev-3):
args
|> maybe_put("chat_id", chat_id)        # /workspace:bind-chat legitimately takes user chat_id=
|> maybe_put("thread_id", thread_id)    # operator may pin a thread
|> maybe_put("app_id", app_id)          # cross-app workflows may take user app_id=
|> force_put("principal_id", principal_id)   # identity = envelope-only, never user-supplied

# helper added next to maybe_put:
defp force_put(map, _key, nil), do: map
defp force_put(map, key, value), do: Map.put(map, key, value)
```

#### 3.5.2 Impact audit (slash-callable consumers of `args["principal_id"]`)

| Module | Path | Effect of overwrite | Status |
|---|---|---|---|
| `Esr.Commands.Whoami` (`whoami.ex:22`) | slash | display-only, `(unknown)` fallback → caller's identity displayed | OK (in fact correct) |
| `Esr.Commands.Doctor` (`doctor.ex:27`) | slash | display-only, fallback "(unknown)" | OK |
| `Esr.Plugins.Feishu.Commands.SelfBind` (NEW) | slash | identity source-of-truth | OK (this spec relies on the fix) |
| `Esr.Plugins.Feishu.Commands.SelfUnbind` (NEW) | slash | identity source-of-truth | OK |
| `Esr.Commands.Cap.{Grant,Revoke,Show}` | internal_kind only | not slash-callable; CLI submits via QueueWatcher, does NOT go through `inject_envelope_args` | UNAFFECTED |
| `Esr.Commands.Session.Share` | internal_kind only | same as above | UNAFFECTED |
| `Esr.Commands.CrossAppTest` | internal_kind only | same as above | UNAFFECTED |
| `Esr.Commands.User.{Add,Switch}` | internal_kind only | builds `principal_id` in result map; doesn't read `args["principal_id"]` from input | UNAFFECTED |

The change is genuinely surgical: only `inject_envelope_args/2` (slash-text dispatch path) is touched; the internal-kind / CLI submission path is independent.

#### 3.5.3 Why not also force-overwrite `username`?

`merge_chat_context` (`slash_handler.ex:705`, `723`) also uses `maybe_put("username", ...)`, with the same vulnerability shape — anyone typing `username=victim` against `/session:new` could potentially spoof username. **Out of scope for this spec** — different consumers (session-aware commands), different blast radius (caps key on principal_id, not username), and the audit deserves its own pass. Tracked in `docs/futures/todo.md`.

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
  · whitelist check: Map.keys(args) -- @allowed_keys must be []
  · pattern-match {name, principal_id} both non-empty binary
  · args2 = Map.put(args, "feishu_user_id", principal_id)
  · BindUser.execute(%{"args" => args2})
  · :telemetry.execute([:esr, :slash, :feishu, :self_bind], ...)
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
  · whitelist check: Map.keys(args) -- @allowed_keys must be []
    (rejects user-supplied `name=` or `feishu_user_id=` etc)
  · principal_id from args (envelope-injected)
  · scan users.yaml, find entry where ou_xxx ∈ feishu_ids
    · not found → {:ok, "ou_xxx not bound to any esr user"}  (idempotent)
    · found in users[Y] → delegate to UnbindUser.execute(%{
        "args" => %{"name" => Y, "feishu_user_id" => principal_id}
      })
  · UnbindUser writes yaml, returns {:ok, "unbound ... from Y"}
  · :telemetry.execute([:esr, :slash, :feishu, :self_unbind], ...)
```

`SelfUnbind` does the lookup + delegates so the actual yaml mutation lives in one place (`UnbindUser`). The lookup is `Enum.find_value(users, fn {n, row} -> if fid in (row["feishu_ids"] || []), do: n end)`.

### 4.3 SelfBind module (full pseudocode)

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfBind do
  @moduledoc """
  Slash-only self-bind wrapper for `/feishu:bind`. Reads the caller's
  Feishu open_id from the envelope-injected `args["principal_id"]`,
  delegates to BindUser.

  Any args key not in `@allowed_keys` is rejected as `invalid_args` —
  this closes the attack-injection path (caller passing
  `feishu_user_id=ou_VICTIM`) and gives clear feedback for typos. The
  whitelist enumerates user-typed keys (`name`) plus envelope-injected
  keys (`principal_id`/`chat_id`/`app_id`/`thread_id`).

  Admin-代-bind takes the BindUser path directly via the `feishu_bind`
  internal_kind (CLI submit, gated by `feishu/user-bind`).
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.BindUser

  @allowed_keys ~w(name principal_id chat_id app_id thread_id)

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) do
    result =
      case Map.keys(args) -- @allowed_keys do
        [] -> do_bind(args)
        extras -> reject_extras(extras)
      end

    :telemetry.execute(
      [:esr, :slash, :feishu, :self_bind],
      %{},
      %{
        name: Map.get(args, "name"),
        principal_id: Map.get(args, "principal_id"),
        result: result_tag(result)
      }
    )

    result
  end

  def execute(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:bind requires args (envelope must inject principal_id)"}}

  defp do_bind(%{"name" => name, "principal_id" => p} = args)
       when is_binary(name) and name != "" and is_binary(p) and p != "" do
    args = Map.put(args, "feishu_user_id", p)
    BindUser.execute(%{"args" => args})
  end

  defp do_bind(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:bind needs args.name; caller ou_xxx is auto-injected from the envelope"}}

  defp reject_extras(extras), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:bind does not accept: #{Enum.join(extras, ", ")}"}}

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, %{"type" => t}}), do: t
  defp result_tag(_), do: :unknown
end
```

The `@allowed_keys` whitelist duplicates the manifest's `args:` declaration for `name`. This is acknowledged duplication; § 8 lists "registry-driven arg validation" as a future refactor that pulls allowed keys from the route metadata. For rev-1, explicit whitelist is simpler and one-time-auditable.

### 4.4 SelfUnbind module (full pseudocode)

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfUnbind do
  @moduledoc """
  Slash-only self-unbind wrapper for `/feishu:unbind`. Looks up which
  esr user currently owns the caller's `ou_xxx` and delegates to
  UnbindUser. Idempotent if the caller has no binding.

  Any args key not in `@allowed_keys` is rejected as `invalid_args`
  (mirrors SelfBind contract). The slash declares `args: []`, so
  user-supplied keys are always rejected; envelope-injected keys
  (principal_id, chat_id, app_id, thread_id) are allowed through.
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.UnbindUser

  @allowed_keys ~w(principal_id chat_id app_id thread_id)

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) do
    result =
      case Map.keys(args) -- @allowed_keys do
        [] -> do_unbind(args)
        extras -> reject_extras(extras)
      end

    :telemetry.execute(
      [:esr, :slash, :feishu, :self_unbind],
      %{},
      %{
        principal_id: Map.get(args, "principal_id"),
        result: result_tag(result)
      }
    )

    result
  end

  def execute(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind requires args (envelope must inject principal_id)"}}

  defp do_unbind(%{"principal_id" => p}) when is_binary(p) and p != "" do
    case lookup_owner(p) do
      nil -> {:ok, %{"text" => "#{p} is not bound to any esr user"}}
      name ->
        case UnbindUser.execute(%{"args" => %{"name" => name, "feishu_user_id" => p}}) do
          # Race remap (spec § 7.2): if a concurrent admin unbind landed
          # between our lookup_owner and UnbindUser's read, UnbindUser
          # returns user_not_found. From the self-unbind caller's
          # perspective this is identical to "no longer bound" — collapse
          # to idempotent ok rather than confusing the user with a
          # principal-namespace error.
          {:error, %{"type" => "user_not_found"}} ->
            {:ok, %{"text" => "#{p} is no longer bound (raced concurrent unbind)"}}

          other -> other
        end
    end
  end

  defp do_unbind(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind requires an envelope-injected principal_id"}}

  defp reject_extras(extras), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind does not accept: #{Enum.join(extras, ", ")}"}}

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, %{"type" => t}}), do: t
  defp result_tag(_), do: :unknown

  # Non-atomic read: lookup_owner reads users.yaml, then the delegated
  # UnbindUser.execute reads it again to mutate. A concurrent admin
  # `feishu_unbind` between the two reads can cause a stale `name` →
  # UnbindUser returns user_not_found. Acceptable per spec § 7.2 —
  # idempotent retry recovers; probability is low (admin + user
  # racing the same identity within milliseconds).
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

### 4.5 Telemetry events

Both wrappers emit a `:telemetry` event on every invocation:

| Event | Measurements | Metadata |
|---|---|---|
| `[:esr, :slash, :feishu, :self_bind]` | `%{}` | `%{name, principal_id, result}` |
| `[:esr, :slash, :feishu, :self_unbind]` | `%{}` | `%{principal_id, result}` |

`result` is an atom: `:ok` on success, or the error type string (e.g. `"invalid_args"`, `"feishu_id_in_use"`, `"user_not_found"`, `"write_failed"`).

Rationale (per user feedback in rev-2 review): bind/unbind are security-sensitive identity mutations. SlashHandler's `[:esr, :slash, :*]` system-layer events log the dispatch entry but not result-level outcomes per command. Per-command emission keeps the audit trail intact even if SlashHandler's log levels are dialed down.

Cost: ~10 LOC (the helper `result_tag/1` + the `:telemetry.execute/3` call) plus one assertion per command in tests using `:telemetry_test.attach_event_handlers/2` (the project-standard pattern; see `runtime/lib/esr/plugins/claude_code/cc_process.ex:240,251,370` for emitter examples).

`SelfUnbind` does the lookup + delegates so the actual yaml mutation lives in one place (`UnbindUser`). The lookup is `Enum.find_value(users, fn {n, row} -> if fid in (row["feishu_ids"] || []), do: n end)`.

## 5. Error semantics

### 5.1 `/feishu:bind name=X`

| Input | Behavior | error type |
|---|---|---|
| any non-allowed key in args (e.g. `feishu_user_id=`, `random_arg=`) | error (`@allowed_keys` whitelist rejection) | `invalid_args` |
| missing `name=` or envelope lacks `ou_xxx` | error | `invalid_args` |
| `name=X` does not exist | error | `user_not_found` (existing) |
| caller `ou_xxx` already in `users[X].feishu_ids` | idempotent ok | — |
| caller `ou_xxx` in `users[Y].feishu_ids`, Y ≠ X | error (suggest `/feishu:unbind` first) | `feishu_id_in_use` (existing) |
| `users[X]` exists, has other `ou_xxx`s already | append (multi-device) | ok |
| yaml write fails | error | `write_failed` (existing) |

The whitelist check fires **before** any other validation. Rejecting `feishu_user_id=` closes the identity-injection path: a malicious chat member cannot pass `feishu_user_id=ou_VICTIM` to bind a third party's `ou_xxx`. The same mechanism rejects accidental typos (`naem=linyilun`) with a clear message instead of silently parsing as a no-op.

`feishu_id_in_use` message text is improved from the existing form to include the actionable next step:

```
feishu_id ou_xxx is already bound to esr user 'Y'; run /feishu:unbind first, then /feishu:bind name=X
```

**Project-wide adoption** — currently only SelfBind / SelfUnbind use the `@allowed_keys` strict-args pattern. Most other commands use permissive pattern-matching and ignore extras. § 8 lists "promote strict-args to a project-wide convention" as future work.

### 5.2 `/feishu:unbind`

| Input | Behavior | error type |
|---|---|---|
| envelope lacks `ou_xxx` | error | `invalid_args` |
| caller `ou_xxx` not in any `users[*].feishu_ids` | idempotent ok | — |
| caller `ou_xxx` in `users[Y].feishu_ids` | unbind, reply `unbound from <Y>` | — |
| yaml write fails | error | `write_failed` (existing in UnbindUser) |

## 6. Test plan

### 6.1 `self_bind_test.exs` (unit, 11 cases, `async: false`)

Each test sets up `ESRD_HOME` tmp + a `users.yaml` fixture, calls `SelfBind.execute/1` directly, asserts result + on-disk yaml. Telemetry-asserting cases use `:telemetry_test.attach_event_handlers/2` to attach a forwarder before invocation.

| # | Case | Expected |
|---|---|---|
| 1 | golden — `users[linyilun]` exists with `feishu_ids: []`, call with `principal_id=ou_X` | `:ok`, yaml gains `[ou_X]` |
| 2 | idempotent — `users[linyilun].feishu_ids: [ou_X]`, call again | `:ok`, yaml unchanged |
| 3 | multi-bind append — `users[linyilun].feishu_ids: [ou_OTHER]`, call `principal_id=ou_X` | `:ok`, yaml = `[ou_OTHER, ou_X]` |
| 4 | conflict — `users[bob].feishu_ids: [ou_X]`, call `name=linyilun principal_id=ou_X` | `{:error, %{"type" => "feishu_id_in_use"}}` |
| 5 | user_not_found — `name=ghost` not in users.yaml | `{:error, %{"type" => "user_not_found"}}` |
| 6 | invalid — missing `name=` | `{:error, %{"type" => "invalid_args"}}` |
| 7 | invalid — missing `principal_id=` (envelope-anomaly fallback) | `{:error, %{"type" => "invalid_args"}}` |
| 8 | reject `feishu_user_id=` — args carry both `principal_id=ou_X` and `feishu_user_id=ou_VICTIM` | `{:error, %{"type" => "invalid_args"}}`, yaml unchanged — closes attack-injection path |
| 9 | reject arbitrary unknown key — args carry `name=linyilun` + `random_arg=foo` | `{:error, %{"type" => "invalid_args"}}` mentioning `random_arg`, yaml unchanged |
| 10 | telemetry on success — case 1 setup + attached telemetry handler | `[:esr, :slash, :feishu, :self_bind]` event observed with `metadata.result == :ok`, `metadata.name == "linyilun"`, `metadata.principal_id == "ou_X"` |
| 11 | telemetry on error — case 4 setup + attached telemetry handler | event observed with `metadata.result == "feishu_id_in_use"` |

### 6.2 `self_unbind_test.exs` (unit, 10 cases, `async: false`)

| # | Case | Expected |
|---|---|---|
| 1 | golden — `users[linyilun].feishu_ids: [ou_X]`, call `principal_id=ou_X` | `:ok`, reply contains `unbound`, `from linyilun`; yaml = `[]` |
| 2 | idempotent — `ou_X` not in any user | `:ok`, reply contains `not bound`; yaml unchanged |
| 3 | partial removal — `users[linyilun].feishu_ids: [ou_X, ou_Y]`, call `principal_id=ou_X` | `:ok`, yaml = `[ou_Y]` |
| 4 | invalid — missing `principal_id=` | `{:error, %{"type" => "invalid_args"}}` |
| 5 | reject `feishu_user_id=` — args carry `principal_id=ou_X` and `feishu_user_id=ou_OTHER` | `{:error, %{"type" => "invalid_args"}}`, yaml unchanged |
| 6 | reject `name=` — args carry `principal_id=ou_X` and `name=linyilun` (cross-account unbind not allowed) | `{:error, %{"type" => "invalid_args"}}` |
| 7 | yaml write fails — make `users.yaml` parent dir read-only (skip on root/EUID==0) | `{:error, %{"type" => "write_failed"}}` |
| 8 | race remap — manually invoke with `principal_id=ou_X` against a yaml shape that simulates "lookup_owner found but UnbindUser sees gone" (write yaml between lookup and UnbindUser via mocked path or pre-stage two yaml files) | `:ok`, reply contains `no longer bound`, `raced` |
| 9 | telemetry on success — case 1 setup + attached handler | `[:esr, :slash, :feishu, :self_unbind]` event with `metadata.result == :ok`, `metadata.principal_id == "ou_X"` |
| 10 | telemetry on idempotent — case 2 setup + attached handler | event with `metadata.result == :ok` (idempotent counts as success) |

> Implementation note for case 8: simulating the race deterministically without internal hooks is hard. Acceptable patterns: (a) extract `lookup_owner/1` to a public function, mock `:meck` it to return a name that doesn't exist in the on-disk yaml (cleanest); (b) stub `UnbindUser` via `Mox` to return `{:error, %{"type" => "user_not_found"}}`. The plan picks (a) because the codebase doesn't currently use `Mox` for command-level stubs.

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

### 7.2 `users.yaml` non-atomic read in `SelfUnbind` (rev-3 mitigation)

`lookup_owner/1` and `UnbindUser.execute/1` each read `users.yaml` independently. A concurrent admin-代-unbind could complete between the two reads, making the second read see no entry — `UnbindUser` then errors `user_not_found`. **Rev-3 mitigation**: SelfUnbind catches `user_not_found` from the delegated UnbindUser and remaps it to idempotent `{:ok, "is no longer bound (raced concurrent unbind)"}`. From the self-unbind caller's perspective the binding is gone, which is the correct user-facing semantic. The race is now invisible to the caller. Code lives in § 4.4 `do_unbind/1`; tested by case 8.

### 7.3 Resolved: telemetry now emitted (rev-2)

Original rev-1 question — should self-bind / self-unbind emit a telemetry event for audit logging — was resolved **yes** during user review. § 4.5 documents the event shape; § 6.1 cases 10-11 + § 6.2 cases 8-9 cover assertions. Rationale: bind/unbind are security-sensitive identity mutations, and SlashHandler's `[:esr, :slash, :*]` system-layer events log dispatch entry but not result-level outcomes per command.

## 8. Future work (out of scope)

- **Claim-token gating.** If chat-membership trust proves insufficient, `user_add` could optionally generate a single-use, time-bound token printed once, given to the user out-of-band. `/feishu:bind name=X token=<T>` would gate the bind. Adds ~150 LOC + token storage; deferred until needed.
- **Symmetric Telegram self-bind.** When Telegram plugin matures, mirror this design: `/telegram:bind` in the telegram plugin's manifest. The pattern (envelope-only, strict-args, delegate to existing admin command) is platform-agnostic.
- **Strict-args (`@allowed_keys`) project-wide adoption.** Currently only SelfBind / SelfUnbind reject unknown args. Tracked in `docs/futures/todo.md` (Pending — concrete next PRs). **Depends on `use Esr.Commands.Meta`** (spec `2026-05-09-unified-command-grammar-and-errors.md`, in flight): once Meta lands, every command exposes `command_meta/0` with a declared `args:` list — that becomes the natural single-source-of-truth for the allowed-key set. After Meta lands, the local `@allowed_keys` lists in SelfBind/SelfUnbind should be removed and the check should read from `command_meta().args` plus a fixed env-injected key allowlist (`principal_id`/`chat_id`/`app_id`/`thread_id`/`username`). Sequencing avoids backwards-compat juggling later.
- **Registry-driven arg validation in SlashHandler.** Alternative to per-command `@allowed_keys`: pre-validate at dispatch time using the route's manifest `args:` declaration. Cleaner DRY but couples SlashHandler to the manifest schema; deferred until the per-command pattern shows enough adoption to justify lifting it. Likely subsumed by `Esr.Commands.Meta` once that spec ships.

## 9. Summary of decisions

1. New slash names: `/feishu:bind`, `/feishu:unbind` — plugin-owned, registered in feishu manifest. Symmetric for future `/telegram:bind` etc.
2. Permission: `null` (chat-membership trust). Justified by pre-existing `user_add` admin gate + bot-membership operator control.
3. Bundle bind + unbind in same spec — operationally inseparable (re-bind requires unbind first).
4. Bind conflict: error with actionable hint, no silent rebind, no `force=` flag.
5. Implementation: thin wrapper modules (`SelfBind`, `SelfUnbind`) delegating to existing `BindUser` / `UnbindUser`. **Core SlashHandler is modified by exactly one line** (rev-3) — `principal_id` switches from `maybe_put` (Map.put_new) to `force_put` (Map.put) so envelope identity wins over user-supplied args.
6. Strict args via per-command `@allowed_keys` whitelist — any non-whitelisted key (incl. caller-supplied `feishu_user_id=`) rejected as `invalid_args`. Project-wide adoption deferred — tracked in `docs/futures/todo.md`.
7. Telemetry events `[:esr, :slash, :feishu, :self_bind]` and `[:esr, :slash, :feishu, :self_unbind]` emitted on every invocation — security-sensitive identity mutations get an audit trail.
8. `/feishu:unbind` takes no user-supplied args — always operates on caller's `ou_xxx`. Unbind-by-name stays admin CLI.
9. SelfUnbind's two-step lookup-then-delegate race is **mitigated** in rev-3 — `user_not_found` from UnbindUser is remapped to idempotent `:ok` so the caller never sees a confusing principal-namespace error.
10. `username` has the same identity-spoof shape but different blast radius and consumers — out of scope, tracked in `docs/futures/todo.md` for a separate audit.
