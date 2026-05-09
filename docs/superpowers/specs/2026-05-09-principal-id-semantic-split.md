# `principal_id` semantic split — `caller_principal_id` vs `target_principal_id`

**Spec id:** 2026-05-09-principal-id-semantic-split
**Author:** Allen Woods + Claude
**Status:** rev-1 (post-pivot from feishu-slash-bind rev-3)
**Tracks:** unblocks `/feishu:bind` self-service slash; closes a security gap surfaced during that brainstorm

## 0. Pivot history (rev-1 = post-pivot rev-4 of original feishu-slash-bind spec)

This spec was originally `2026-05-09-feishu-slash-bind-design.md` (rev-1 → rev-3, growing scope each pass). Subagent review of rev-3 caught that the rev-3 fix (`force_put` for `principal_id` in `inject_envelope_args/2`) silently regresses `/cap:grant`, `/cap:revoke`, `/cap:show`, `/session:share`, and `/cross_app_test` because those commands read `args["principal_id"]` as the **operation target**, not the caller. Same key, two semantics, irreducible conflict.

User decision (2026-05-09): pivot scope. Primary objective is now the `principal_id` semantic split; `/feishu:bind` self-service is a downstream beneficiary case study (Part B). File renamed via `git mv`; the old `feishu-slash-bind-design.md` history is preserved in git.

## 1. Problem statement

`args["principal_id"]` carries two semantically opposite meanings depending on the command:

| Semantic | Source of truth | Example commands |
|---|---|---|
| **CALLER** identity (who is invoking) | envelope (security-critical) | `whoami`, `doctor`, future `/feishu:bind` |
| **TARGET** of operation (whom is the action about) | user-supplied (whole point of the command) | `cap/grant`, `cap/revoke`, `cap/show`, `session/share`, `cross_app_test` |

This conflation is **irreducibly broken** for any single write strategy in `Esr.Entity.SlashHandler.inject_envelope_args/2`:

- **`maybe_put` (Map.put_new)** — preserves user-supplied value. Target commands work; caller commands have a security gap (a malicious chat member typing `/feishu:bind name=linyilun principal_id=ou_VICTIM` retains `ou_VICTIM` as the caller identity).
- **`Map.put`** — overwrites user-supplied value with envelope. Caller commands secure; target commands silently regress (admin running `/cap:grant principal_id=ou_TARGET permission=foo` ends up granting to themselves because `ou_TARGET` is replaced by the admin's own envelope `principal_id`).

Neither strategy can satisfy both semantic uses. The fix is to give them **different names**:

- `args["caller_principal_id"]` — envelope-only, force-overwritten by SlashHandler. Read by caller-aware commands.
- `args["target_principal_id"]` — user-supplied, never touched by SlashHandler. Read by target-aware commands.

The legacy `args["principal_id"]` key is **removed** from the args layer entirely (hard-cut, see § 3.5). `principal_id` continues to mean "caller identity" at the **envelope** layer (`envelope["principal_id"]`, socket assigns, `cap_guard`, registry rows, `{:tool_invoke, _, principal_id}` tuples) — that layer is unambiguous and out of scope.

## 2. Non-goals

- **Not** changing the envelope/socket layer. `envelope["principal_id"]` remains the canonical name for caller identity at message ingress.
- **Not** introducing back-compat aliasing. Hard-cut: every `args["principal_id"]` reader is renamed in this PR, every test fixture is updated, every CLI submitter is updated.
- **Not** redesigning cap UX (`cap=`, `user=` shortcuts at the slash layer). Out of scope; `target_principal_id` is verbose but consistent.
- **Not** designing a route-metadata `envelope_authoritative:` declaration mechanism. The two-key split makes it unnecessary.
- **Not** auditing or fixing the same vulnerability shape on `username` (also `maybe_put` in `merge_chat_context`). Tracked in `docs/futures/todo.md` for a separate audit.

## 3. Design

### 3.1 Files (Part A — semantic split)

| File | Action | Notes |
|---|---|---|
| `runtime/lib/esr/entity/slash_handler.ex` | edit | inject `caller_principal_id` (force_put) instead of `principal_id` (maybe_put); add `force_put/3` helper |
| `runtime/lib/esr/commands/whoami.ex` | edit | read `args["caller_principal_id"]` |
| `runtime/lib/esr/commands/doctor.ex` | edit | read `args["caller_principal_id"]` |
| `runtime/lib/esr/commands/cap/grant.ex` | edit | pattern match `target_principal_id`; output map keeps `principal_id` for stability of programmatic consumers (verified via output-only audit) |
| `runtime/lib/esr/commands/cap/revoke.ex` | edit | pattern match `target_principal_id`; output map same |
| `runtime/lib/esr/commands/cap/show.ex` | edit | pattern match `target_principal_id` |
| `runtime/lib/esr/commands/session/share.ex` | edit | call `Grant.execute(%{"args" => %{"target_principal_id" => uuid, "permission" => cap}})` |
| `runtime/lib/esr/commands/cross_app_test.ex` | edit | `fetch_arg(args, "target_principal_id")` |
| `runtime/priv/slash-routes.default.yaml` | edit | `/cap:grant`, `/cap:revoke`, `/cap:show` slash schemas → `args: target_principal_id, permission` (replace `cap, user`) |
| `runtime/lib/esr/cli/main.ex` | edit if needed | escript `cap grant` subcommand may build args directly — audit the kw→args translation, switch to new names |

### 3.2 Files (Part B — `/feishu:bind` self-service, downstream beneficiary)

After Part A lands, Part B becomes simple:

| File | Action | Notes |
|---|---|---|
| `runtime/lib/esr/plugins/feishu/commands/self_bind.ex` | new | reads `args["caller_principal_id"]`; whitelist allows `name`, `caller_principal_id`, `chat_id`, `app_id`, `thread_id` |
| `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex` | new | reads `args["caller_principal_id"]`; whitelist allows envelope-injected keys only; race-remap (rev-3 § 4.4) preserved |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | edit | register `/feishu:bind`, `/feishu:unbind` slashes (unchanged from rev-3) |
| Tests for both | new | unit + registry tests as in rev-3 § 6.1 / § 6.2 |

### 3.3 Test files (mass-rename + new)

| File | Action |
|---|---|
| `runtime/test/esr/entity/slash_handler_dispatch_test.exs` | append: assert `inject_envelope_args/2` writes `caller_principal_id` and never overwrites a user-supplied `target_principal_id` (or any other key) |
| `runtime/test/esr/commands/whoami_test.exs` | edit `principal_id` → `caller_principal_id` |
| `runtime/test/esr/commands/doctor_test.exs` | same |
| `runtime/test/esr/commands/cap_test.exs` | ~13 `principal_id` references → `target_principal_id` |
| `runtime/test/esr/commands/cap/grant_test.exs` | 3 → `target_principal_id` |
| `runtime/test/esr/commands/cap/revoke_test.exs` | 2 → `target_principal_id` |
| `runtime/test/esr/commands/cap/uuid_translation_test.exs` | 8 → `target_principal_id` |
| `runtime/test/esr/commands/cross_app_test_test.exs` | 3 → `target_principal_id` |
| `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs` | new |
| `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs` | new |
| `runtime/test/esr/plugins/feishu/commands/migration_test.exs` | append 4 registry asserts for `/feishu:bind`, `/feishu:unbind` |

Output-only test sites (`runtime/test/esr/commands/user/add_test.exs`, `user/switch_test.exs`, `cli/main_test.exs`) — **do not change**, the output map's `principal_id` key is preserved for programmatic stability.

### 3.4 SlashHandler change

Replace this block in `inject_envelope_args/2` (`slash_handler.ex:662-673`):

```elixir
# BEFORE
defp inject_envelope_args(args, envelope) do
  chat_id = envelope_chat_id(envelope)
  thread_id = envelope_thread_id(envelope)
  app_id = get_in(envelope, ["payload", "args", "app_id"])
  principal_id = envelope["principal_id"] || envelope["user_id"]

  args
  |> maybe_put("chat_id", chat_id)
  |> maybe_put("thread_id", thread_id)
  |> maybe_put("app_id", app_id)
  |> maybe_put("principal_id", principal_id)
end

# AFTER
defp inject_envelope_args(args, envelope) do
  chat_id = envelope_chat_id(envelope)
  thread_id = envelope_thread_id(envelope)
  app_id = get_in(envelope, ["payload", "args", "app_id"])
  caller_principal_id = envelope["principal_id"] || envelope["user_id"]

  args
  |> maybe_put("chat_id", chat_id)
  |> maybe_put("thread_id", thread_id)
  |> maybe_put("app_id", app_id)
  |> force_put("caller_principal_id", caller_principal_id)
end

defp force_put(map, _key, nil), do: map
defp force_put(map, key, value), do: Map.put(map, key, value)
```

**No `principal_id` key in args anymore.** A user typing `principal_id=ou_xxx` against any slash gets that key delivered (text parser doesn't strip it), but no command pattern-matches it after this PR. The legacy key becomes dead at the args layer.

### 3.5 Why hard-cut, not aliased deprecation

User decision (back-compat Q): hard-cut wins because:

1. The audit shows **9 lib/ sites** read `args["principal_id"]` (excluding output-only). Renaming all is bounded and reviewable.
2. Tests provide regression detection — running the suite catches any consumer we forget.
3. ESR is currently single-operator / pre-prod — no external automation depends on the args-layer key shape.
4. Aliased deprecation period adds ~50% extra LOC (every consumer accepts both names; warnings; cleanup PR later) and confuses readers about which is canonical.

CI `mix test` is the safety net.

### 3.6 Schema fix for `/cap:grant`, `/cap:revoke`, `/cap:show`

User decision (schema Q): align schema with cmd, using new names. Today the slash schema declares `args: cap, user` while the cmd pattern-matches `principal_id, permission` — the slash form is **already broken** (validate_required on cap+user passes, then cmd pattern fails). The schema fix is overdue regardless of this rename.

After this PR:

```yaml
"/cap:grant":
  args:
    - { name: target_principal_id, required: true }
    - { name: permission, required: true }

"/cap:revoke":
  args:
    - { name: target_principal_id, required: true }
    - { name: permission, required: true }

"/cap:show":
  args:
    - { name: target_principal_id, required: true }
```

Slash UX is verbose (`/cap:grant target_principal_id=ou_xxx permission=foo`) but consistent with cmd. Shorter aliases (`user=`, `cap=`) are a separate UX spec.

## 4. Migration audit (full inventory)

### Lib/ sites (9 reads + 1 inject; output-only ignored)

```
INJECTOR (1):
  runtime/lib/esr/entity/slash_handler.ex:672

CALLER (2):
  runtime/lib/esr/commands/whoami.ex:22       (display + (unknown) fallback)
  runtime/lib/esr/commands/doctor.ex:27       (display + bind-feishu hint)

TARGET (7 sites in 5 files):
  runtime/lib/esr/commands/cap/grant.ex:38    (system:bootstrap sentinel)
  runtime/lib/esr/commands/cap/grant.ex:51    (target principal pattern match)
  runtime/lib/esr/commands/cap/revoke.ex:37   (target pattern match)
  runtime/lib/esr/commands/cap/show.ex:18     (target lookup)
  runtime/lib/esr/commands/session/share.ex:49 (writes target into Grant sub-call)
  runtime/lib/esr/commands/cross_app_test.ex:57 (fetch_arg target)

OUTPUT-ONLY (do not change):
  runtime/lib/esr/commands/cap/grant.ex:100   (return map "principal_id" key)
  runtime/lib/esr/commands/cap/revoke.ex:84   (return map)
  runtime/lib/esr/commands/user/add.ex:298    (operator.json field)
  runtime/lib/esr/commands/user/switch.ex:26,43 (return + operator.json)
  runtime/lib/esr/cli/main.ex:320             (reads operator.json field)

OUT OF SCOPE (envelope/socket/tool_invoke layer — keeps "principal_id" name):
  runtime/lib/esr_web/{adapter_channel,channel_channel,mcp_controller}.ex
  runtime/lib/esr/entity/{cap_guard,server,proxy}.ex
  runtime/lib/esr/session/{router,process,agent_spawner}.ex
  runtime/lib/esr/resource/adapter_socket/registry.ex
  runtime/lib/esr/plugins/feishu/{feishu_chat_proxy,feishu_app_adapter}.ex
  (~14 files, ~30 sites)
```

### Test sites (~50 hits across ~25 files)

Already broken into CALLER (~5) / TARGET (~32) / envelope-context (~25) / output-only (~10) by the audit. Renames track 1:1 with lib/ changes.

## 5. Invariants after refactor

Post-refactor invariants the test suite enforces:

1. **`args["caller_principal_id"]` is set iff envelope had `principal_id` or `user_id`**. SlashHandler-level test asserts this.
2. **User-supplied `args["caller_principal_id"]` is overwritten by envelope.** Asserted by a dispatch-level test that constructs `args = %{"caller_principal_id" => "ou_VICTIM"}` and an envelope with `principal_id = "ou_real"`, then checks the post-injection args.
3. **User-supplied `args["target_principal_id"]` is preserved untouched.** Asserted by injecting an envelope and checking that an explicit `target_principal_id=ou_X` in args remains `ou_X`.
4. **No command in `runtime/lib/esr/commands/**/*.ex` reads `args["principal_id"]` after this PR.** Verified by a `grep` smoke check at end of plan; tracked separately as a future CI gate.

## 6. Test plan

### 6.1 Net new tests

- `slash_handler_dispatch_test.exs` — assert invariants 1, 2, 3 above. ~3 tests, ~30 LOC.
- `self_bind_test.exs` — 11 cases as in rev-3 § 6.1, with `caller_principal_id` substituted. ~180 LOC.
- `self_unbind_test.exs` — 10 cases (incl. race-remap) as in rev-3 § 6.2, with `caller_principal_id`. ~160 LOC.
- `migration_test.exs` (feishu plugin commands) — 4 new asserts for `/feishu:bind`, `/feishu:unbind` registry entries. +20 LOC.

### 6.2 Mass-update tests

Per-file mechanical search-and-replace:

- 2 caller-semantic test files: `principal_id` → `caller_principal_id` in args context.
- 5 target-semantic test files: `principal_id` → `target_principal_id` in args context.
- Output-only assertions (~10 sites): **do not touch**.

The TDD plan handles each file as its own task to keep the diff reviewable.

### 6.3 Stability constraints

- All command tests continue to use `async: false` where they touch `ESRD_HOME`.
- New SlashHandler invariant tests: `async: true` is fine — they construct envelopes/args directly without env vars.
- Telemetry-emitting tests (Part B) use the project-standard `:telemetry_test.attach_event_handlers/2` pattern.

## 7. Risk + open questions

### 7.1 Hidden cmd consumers I missed in the audit

Mitigation: TDD task ordering runs the full suite after each file change. A missed consumer surfaces as a test failure at that step.

### 7.2 `validate_required/3` may currently accept the legacy slash form

Today `/cap:grant cap=foo user=bob` passes `validate_required` (cap+user both present per old schema) but fails cmd pattern-match. After this PR's schema fix, `validate_required` will demand `target_principal_id+permission`. Operators / scripts using `cap=user=` will now hit `validate_required` rejection instead of cmd-pattern fall-through. Both pre-fix and post-fix the form fails, but the **failure point shifts** — error message changes from "function clause not matched" to `missing_required_args`. Acceptable; net better UX.

### 7.3 `cli/main.ex` escript args translation

Audit shows `cli/main.ex:320` reads `operator.json`'s `principal_id` field — output-only, unaffected. But the escript also constructs args for slash submission (e.g. `esr cap grant ou_xxx perm.foo`). The plan's first cap-related Task verifies in code that the kw→args translation builds `target_principal_id` not `principal_id`.

### 7.4 `username` shape vulnerability deferred

`merge_chat_context` injects `username` via `maybe_put` (`slash_handler.ex:705,723`). Same shape, different consumers, different blast radius (caps key on `principal_id`, not `username`). Deferred to `docs/futures/todo.md`. This spec does not pretend to solve it.

### 7.5 SHA divergence pressure

`origin/dev` is currently 19 commits ahead of this branch. After landing this PR, follow CLAUDE.md `dev → main` promotion in the same session.

## 8. Future work (out of scope)

- **`username` semantic split** — same shape as this spec but for `merge_chat_context`'s `username` injection. Deferred.
- **Slash UX shortcuts** — `/cap:grant user=bob cap=user.manage` short-form with translation to `target_principal_id=<resolved> permission=<resolved>`. Pure UX, separate spec.
- **CI grep gate** — automated check that no command module reads `args["principal_id"]` (only the renamed forms or output map writes). One-line CI step; tracked in `docs/futures/todo.md`.
- **Output map split** — separate question of whether `cap/grant`'s return value should also rename `principal_id` → `target_principal_id`. Output stability matters more than args stability for programmatic consumers; keep as is for now.

## 9. Summary of decisions

1. Hard-cut rename, no aliasing, no deprecation period.
2. `caller_principal_id` (envelope, force_put by SlashHandler) + `target_principal_id` (user-supplied, untouched).
3. `/cap:grant`, `/cap:revoke`, `/cap:show` slash schemas updated to match cmd patterns (`target_principal_id, permission`), fixing today's broken-via-slash state as a side effect.
4. `/feishu:bind` + `/feishu:unbind` ship in this same PR as the downstream beneficiary, using `caller_principal_id` directly. All rev-3 design (whitelist, telemetry, race-remap) carried over.
5. Output map keys (`{"principal_id" => uuid, ...}`) unchanged — programmatic stability over symmetry.
6. Envelope/socket/tool_invoke layer unchanged — `principal_id` is unambiguously caller-identity there.
7. `username` same-shape vulnerability tracked separately in `docs/futures/todo.md`.
