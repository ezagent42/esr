# Feishu self-bind (`/feishu:bind` + `/feishu:unbind`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two plugin-owned slash commands `/feishu:bind name=<n>` and `/feishu:unbind` to let Feishu users self-bind / self-unbind their `ou_xxx` to/from an esr user from inside a Feishu chat. Admin path (CLI `feishu_bind` internal_kind) stays unchanged.

**Architecture:** Two thin wrapper modules (`SelfBind`, `SelfUnbind`) under `Esr.Plugins.Feishu.Commands.*`. Each runs an `@allowed_keys` whitelist on `args`, then delegates to the existing `BindUser` / `UnbindUser` modules. Caller's `ou_xxx` is read from `args["principal_id"]` (envelope-injected by `Esr.Entity.SlashHandler.inject_envelope_args/2`). Plugin manifest declares the slashes. Core `SlashHandler` gets **one surgical change** (rev-3, Task 1): `principal_id` switches from `maybe_put` to `force_put` so envelope identity wins over user-supplied args (security precondition for `permission: null`).

**Tech Stack:** Elixir 1.17+, Phoenix LiveView 1.x runtime, ExUnit, `:telemetry` library, YamlElixir for parsing, `Esr.Yaml.Writer` for atomic writes.

**Spec reference:** [`docs/superpowers/specs/2026-05-09-feishu-slash-bind-design.md`](../specs/2026-05-09-feishu-slash-bind-design.md)

---

## Pre-flight — what already exists, what you do NOT touch

| Module | Status |
|---|---|
| `Esr.Plugins.Feishu.Commands.BindUser` (`runtime/lib/esr/plugins/feishu/commands/bind_user.ex`) | EXISTS, **DO NOT MODIFY** |
| `Esr.Plugins.Feishu.Commands.UnbindUser` (`runtime/lib/esr/plugins/feishu/commands/unbind_user.ex`) | EXISTS, **DO NOT MODIFY** |
| `Esr.Entity.SlashHandler.inject_envelope_args/2` (`runtime/lib/esr/entity/slash_handler.ex:662`) | EXISTS — **Task 1 modifies one line** (`principal_id` `maybe_put` → `force_put`) |
| `Esr.Resource.SlashRoute.Registry.command_module_for/1` (`runtime/lib/esr/resource/slash_route/registry.ex:95`) | EXISTS, used in tests |
| `Esr.Resource.SlashRoute.Registry.lookup/1` (`runtime/lib/esr/resource/slash_route/registry.ex:49`) | EXISTS, used in tests |
| `Esr.Paths.users_yaml/0` (`runtime/lib/esr/paths.ex:19`) | EXISTS — returns `<ESRD_HOME>/<ESR_INSTANCE>/users.yaml` |
| `Esr.Yaml.Writer.write/2` (`runtime/lib/esr/yaml/writer.ex:23`) | EXISTS — atomic write helper |
| `slash-routes.default.yaml` | **DO NOT MODIFY** — plugin owns its slashes |

---

## File Structure

| File | Action | Notes |
|---|---|---|
| `runtime/lib/esr/entity/slash_handler.ex` | MODIFY (Task 1) | 1 line `maybe_put` → `force_put` for `principal_id` + 2-line `force_put/3` helper + 1-line test shim |
| `runtime/test/esr/entity/slash_handler_test.exs` | MODIFY (Task 1) | append 1 test for force-overwrite property |
| `runtime/lib/esr/plugins/feishu/commands/self_bind.ex` | NEW | ~50 LOC — wrapper for `/feishu:bind` |
| `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex` | NEW | ~70 LOC — wrapper for `/feishu:unbind` (incl. race-remap) |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | MODIFY | replace `slashes: {}` and append two `internal_kinds:` entries |
| `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs` | NEW | ~180 LOC, 11 cases |
| `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs` | NEW | ~160 LOC, 10 cases (incl. race-remap) |
| `runtime/test/esr/plugins/feishu/commands/migration_test.exs` | MODIFY | append 4 registry asserts |

---

## Test fixture pattern (use this in every new test file)

Every new test file uses the same `setup` to point `Esr.Paths.users_yaml/0` at a tmp fixture. Pattern modeled on `runtime/test/esr/entity/user/migration_test.exs:5-18`:

```elixir
setup do
  tmp = Path.join(System.tmp_dir!(), "feishu_self_bind_#{:rand.uniform(1_000_000)}")
  inst_dir = Path.join(tmp, "default")
  File.mkdir_p!(inst_dir)

  prev_home = System.get_env("ESRD_HOME")
  prev_inst = System.get_env("ESR_INSTANCE")
  System.put_env("ESRD_HOME", tmp)
  System.put_env("ESR_INSTANCE", "default")

  on_exit(fn ->
    if prev_home, do: System.put_env("ESRD_HOME", prev_home), else: System.delete_env("ESRD_HOME")
    if prev_inst, do: System.put_env("ESR_INSTANCE", prev_inst), else: System.delete_env("ESR_INSTANCE")
    File.rm_rf!(tmp)
  end)

  {:ok, inst_dir: inst_dir}
end

defp write_users_yaml(inst_dir, content), do: File.write!(Path.join(inst_dir, "users.yaml"), content)
defp read_users_yaml(inst_dir), do: YamlElixir.read_from_file!(Path.join(inst_dir, "users.yaml"))
```

`use ExUnit.Case, async: false` — required because `System.put_env/2` is global.

---

## Task 1: SlashHandler `principal_id` force-overwrite (security precondition)

**Why this comes first:** SelfBind / SelfUnbind read `args["principal_id"]` as the caller's identity. The current `inject_envelope_args/2` (`runtime/lib/esr/entity/slash_handler.ex:662-673`) uses `maybe_put` (= `Map.put_new`) which retains user-supplied `principal_id=ou_VICTIM` over the envelope value. This must land before the new slashes ship — otherwise the `permission: null` chat-trust model is exploitable.

Other envelope-injected keys (`chat_id`, `app_id`, `thread_id`) keep `maybe_put` semantics — `/workspace:bind-chat` legitimately accepts a user-supplied `chat_id=`. Only `principal_id` switches.

Spec reference: § 3.5 + § 3.5.1 + § 3.5.2 (impact audit).

**Files:**
- Modify: `runtime/lib/esr/entity/slash_handler.ex` (1 line + 2-line helper)
- Modify: `runtime/test/esr/entity/slash_handler_test.exs` (1 new test)

- [ ] **Step 1: Add a failing test for the force-overwrite property**

Open `runtime/test/esr/entity/slash_handler_test.exs` and find an existing `describe` block that exercises `inject_envelope_args/2` (or the dispatch path that uses it). Append a new `describe` block:

```elixir
  describe "principal_id is envelope-only (rev-3 security fix)" do
    # User-supplied principal_id= must be discarded in favor of envelope value.
    # Other envelope-injected keys (chat_id, app_id, thread_id) intentionally
    # remain user-overridable — see /workspace:bind-chat.
    test "user-supplied principal_id= is overwritten by envelope's value" do
      envelope = %{
        "principal_id" => "ou_real_caller",
        "user_id" => "ou_real_caller",
        "payload" => %{
          "text" => "/feishu:bind name=linyilun principal_id=ou_VICTIM",
          "args" => %{"app_id" => "cli_xxx"}
        }
      }

      # Re-create SlashHandler's internal pipeline without dispatching:
      # parse text → inject envelope args. The expected outcome is that
      # args["principal_id"] equals the envelope's value, NOT "ou_VICTIM".
      args = %{"name" => "linyilun", "principal_id" => "ou_VICTIM"}
      injected = Esr.Entity.SlashHandler.__inject_envelope_args__(args, envelope)

      assert injected["principal_id"] == "ou_real_caller"
    end
  end
```

(Note: `__inject_envelope_args__/2` is exposed only for testing — Step 3 changes the private `defp inject_envelope_args` to also have a public `def __inject_envelope_args__/2` shim. If the codebase prefers different test exposure conventions, follow them — but the property must be asserted somewhere.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `(cd runtime && mix test test/esr/entity/slash_handler_test.exs --only describe:"principal_id is envelope-only")`
Expected: **FAIL** — `injected["principal_id"]` equals `"ou_VICTIM"` (user value retained by `Map.put_new`).

- [ ] **Step 3: Fix `inject_envelope_args/2` to force-overwrite `principal_id`**

In `runtime/lib/esr/entity/slash_handler.ex`, find the `inject_envelope_args/2` definition (around line 662–673) and the `maybe_put/3` helper near it. Apply this diff:

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
    principal_id = envelope["principal_id"] || envelope["user_id"]

    args
    |> maybe_put("chat_id", chat_id)
    |> maybe_put("thread_id", thread_id)
    |> maybe_put("app_id", app_id)
    |> force_put("principal_id", principal_id)   # rev-3: identity is envelope-only
  end

  # Test-only public shim (rev-3).
  @doc false
  def __inject_envelope_args__(args, envelope), do: inject_envelope_args(args, envelope)

  defp force_put(map, _key, nil), do: map
  defp force_put(map, key, value), do: Map.put(map, key, value)
```

Place `force_put/3` immediately after `maybe_put/3` (whichever order the existing helpers use; mirror the convention).

- [ ] **Step 4: Run the test to verify it passes**

Run: `(cd runtime && mix test test/esr/entity/slash_handler_test.exs --only describe:"principal_id is envelope-only")`
Expected: PASS.

- [ ] **Step 5: Run the full slash_handler test file — regression check**

Run: `(cd runtime && mix test test/esr/entity/slash_handler_test.exs)`
Expected: all green. The change is surgical (`maybe_put` → `force_put` for one key only); other tests should be unaffected. Per the audit in spec § 3.5.2: only `Whoami` and `Doctor` are slash-callable consumers of `args["principal_id"]`, both display-only with `(unknown)` fallback — no behavior regression.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/entity/slash_handler.ex runtime/test/esr/entity/slash_handler_test.exs
git commit -m "$(cat <<'EOF'
fix(slash_handler): force-overwrite principal_id from envelope (security)

inject_envelope_args/2 used maybe_put for principal_id, which retained
user-supplied principal_id=ou_VICTIM over the envelope value. This is
exploitable by chat members invoking permission:null slashes (e.g. the
upcoming /feishu:bind) to spoof identity.

Switch principal_id to force_put (Map.put). Other envelope-injected
keys (chat_id, app_id, thread_id) keep maybe_put — /workspace:bind-chat
legitimately takes user-supplied chat_id=.

Audit (spec § 3.5.2): Whoami / Doctor are the only slash-callable
consumers of args["principal_id"] — both display-only, no regression.
Internal_kind callers (cap/grant, cap/revoke, session/share, etc) do
not go through inject_envelope_args.

Precondition for spec 2026-05-09-feishu-slash-bind-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: SelfBind — golden path + delegation to BindUser

**Files:**
- Create: `runtime/lib/esr/plugins/feishu/commands/self_bind.ex`
- Create: `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs`

- [ ] **Step 1: Write the failing test (case 1, golden path)**

Create `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs`:

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfBindTest do
  use ExUnit.Case, async: false

  alias Esr.Plugins.Feishu.Commands.SelfBind

  setup do
    tmp = Path.join(System.tmp_dir!(), "feishu_self_bind_#{:rand.uniform(1_000_000)}")
    inst_dir = Path.join(tmp, "default")
    File.mkdir_p!(inst_dir)

    prev_home = System.get_env("ESRD_HOME")
    prev_inst = System.get_env("ESR_INSTANCE")
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    on_exit(fn ->
      if prev_home, do: System.put_env("ESRD_HOME", prev_home), else: System.delete_env("ESRD_HOME")
      if prev_inst, do: System.put_env("ESR_INSTANCE", prev_inst), else: System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)

    {:ok, inst_dir: inst_dir}
  end

  defp write_users_yaml(inst_dir, content), do: File.write!(Path.join(inst_dir, "users.yaml"), content)
  defp read_users_yaml(inst_dir), do: YamlElixir.read_from_file!(Path.join(inst_dir, "users.yaml"))

  describe "golden path" do
    test "binds caller ou_xxx to a pre-existing user with empty feishu_ids", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      assert {:ok, %{"text" => text}} =
               SelfBind.execute(%{
                 "args" => %{"name" => "linyilun", "principal_id" => "ou_X"}
               })

      assert text =~ "bound"
      assert text =~ "ou_X"
      assert text =~ "linyilun"

      assert %{"users" => %{"linyilun" => %{"feishu_ids" => ["ou_X"]}}} =
               read_users_yaml(inst_dir)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_bind_test.exs)`
Expected: **FAIL** with `(UndefinedFunctionError) function Esr.Plugins.Feishu.Commands.SelfBind.execute/1 is undefined (module Esr.Plugins.Feishu.Commands.SelfBind is not available)`.

- [ ] **Step 3: Create the minimal SelfBind module**

Create `runtime/lib/esr/plugins/feishu/commands/self_bind.ex`:

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfBind do
  @moduledoc """
  Slash-only self-bind wrapper for `/feishu:bind`. Reads the caller's
  Feishu open_id from the envelope-injected `args["principal_id"]`,
  delegates to BindUser. Admin-代-bind takes the BindUser path
  directly via the `feishu_bind` internal_kind (CLI submit, gated by
  `feishu/user-bind`).
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_bind_test.exs)`
Expected: **1 test, 0 failures.**

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/commands/self_bind.ex runtime/test/esr/plugins/feishu/commands/self_bind_test.exs
git commit -m "$(cat <<'EOF'
feat(feishu): SelfBind wrapper with golden path delegation to BindUser

First slice of /feishu:bind plugin self-bind support. Reads caller's
ou_xxx from envelope-injected principal_id and delegates to the
existing admin BindUser command. Whitelist rejection + telemetry land
in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: SelfBind — delegation edge cases (idempotent / multi-bind / conflict / user_not_found)

**Files:**
- Modify: `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs`
- (No production code change — covers existing BindUser behavior surfaced through SelfBind)

- [ ] **Step 1: Add the new test cases**

Append to `self_bind_test.exs` inside the same `describe "golden path"` or in a new `describe "delegation"`:

```elixir
  describe "delegation to BindUser" do
    test "idempotent — already-bound caller returns ok with no semantic change", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)
      before = read_users_yaml(inst_dir)

      assert {:ok, _} =
               SelfBind.execute(%{
                 "args" => %{"name" => "linyilun", "principal_id" => "ou_X"}
               })

      # Compare parsed structure, not byte-equal — Esr.Yaml.Writer re-emits
      # with sorted keys; a future yaml-formatter change would silently break
      # a byte-equality assertion.
      assert before == read_users_yaml(inst_dir)
    end

    test "multi-bind appends caller ou_xxx alongside existing ones", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_OTHER
      """)

      assert {:ok, _} =
               SelfBind.execute(%{
                 "args" => %{"name" => "linyilun", "principal_id" => "ou_X"}
               })

      assert %{"users" => %{"linyilun" => %{"feishu_ids" => ids}}} =
               read_users_yaml(inst_dir)

      assert "ou_OTHER" in ids
      assert "ou_X" in ids
    end

    test "conflict — caller ou_xxx already bound to another user", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        bob:
          feishu_ids:
            - ou_X
        linyilun:
          feishu_ids: []
      """)

      assert {:error, %{"type" => "feishu_id_in_use"}} =
               SelfBind.execute(%{
                 "args" => %{"name" => "linyilun", "principal_id" => "ou_X"}
               })
    end

    test "user_not_found — pre-existing user record required", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      assert {:error, %{"type" => "user_not_found"}} =
               SelfBind.execute(%{
                 "args" => %{"name" => "ghost", "principal_id" => "ou_X"}
               })
    end
  end

  describe "invalid input" do
    test "missing name= produces invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               SelfBind.execute(%{"args" => %{"principal_id" => "ou_X"}})
    end

    test "missing principal_id (envelope anomaly fallback) produces invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               SelfBind.execute(%{"args" => %{"name" => "linyilun"}})
    end
  end
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_bind_test.exs)`
Expected: **7 tests, 0 failures** (1 from Task 2 + 6 new).

If any case fails: investigate. Most likely cause is a mismatch between BindUser's actual error shape and the test's expected shape — re-read `bind_user.ex:23-69` for the canonical types.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/plugins/feishu/commands/self_bind_test.exs
git commit -m "$(cat <<'EOF'
test(feishu): SelfBind delegation edge cases — idempotent, multi-bind, conflict, user_not_found, invalid args

These cases verify SelfBind correctly forwards BindUser's existing
error semantics through the slash path. No production code changes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: SelfBind — strict-args whitelist (`@allowed_keys`)

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/commands/self_bind.ex`
- Modify: `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs`

- [ ] **Step 1: Write failing tests for the whitelist**

Append to `self_bind_test.exs`:

```elixir
  describe "strict-args whitelist" do
    test "rejects user-supplied feishu_user_id= (closes attack-injection path)", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)
      before = File.read!(Path.join(inst_dir, "users.yaml"))

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SelfBind.execute(%{
                 "args" => %{
                   "name" => "linyilun",
                   "principal_id" => "ou_X",
                   "feishu_user_id" => "ou_VICTIM"
                 }
               })

      assert msg =~ "feishu_user_id"
      assert before == File.read!(Path.join(inst_dir, "users.yaml"))
    end

    test "rejects arbitrary unknown key (typos / generic safety)", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SelfBind.execute(%{
                 "args" => %{
                   "name" => "linyilun",
                   "principal_id" => "ou_X",
                   "random_arg" => "foo"
                 }
               })

      assert msg =~ "random_arg"
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_bind_test.exs)`
Expected: **2 failures** in the new `strict-args whitelist` describe block — the first now silently overwrites and returns `{:ok, _}`, the second silently ignores `random_arg` and returns `{:ok, _}`.

- [ ] **Step 3: Refactor SelfBind to add the whitelist**

Replace the contents of `runtime/lib/esr/plugins/feishu/commands/self_bind.ex` entirely:

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
  def execute(%{"args" => args}) when is_map(args) do
    case Map.keys(args) -- @allowed_keys do
      [] -> do_bind(args)
      extras -> reject_extras(extras)
    end
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
end
```

- [ ] **Step 4: Run the full test file, verify all pass**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_bind_test.exs)`
Expected: **9 tests, 0 failures.**

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/commands/self_bind.ex runtime/test/esr/plugins/feishu/commands/self_bind_test.exs
git commit -m "$(cat <<'EOF'
feat(feishu): SelfBind strict-args (@allowed_keys whitelist)

Reject any args key not in the whitelist with invalid_args. Closes
identity-injection path (caller passing feishu_user_id=ou_VICTIM)
and gives clear feedback for typos like naem= or random_arg=.
Spec § 5.1 + cases 8-9.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: SelfBind — telemetry events

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/commands/self_bind.ex`
- Modify: `runtime/test/esr/plugins/feishu/commands/self_bind_test.exs`

- [ ] **Step 1: Write failing tests for telemetry**

Append to `self_bind_test.exs`:

```elixir
  describe "telemetry" do
    test "emits [:esr, :slash, :feishu, :self_bind] on success", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :slash, :feishu, :self_bind]])

      assert {:ok, _} =
               SelfBind.execute(%{
                 "args" => %{"name" => "linyilun", "principal_id" => "ou_X"}
               })

      assert_receive {[:esr, :slash, :feishu, :self_bind], ^ref, _measurements, metadata}
      assert metadata.result == :ok
      assert metadata.name == "linyilun"
      assert metadata.principal_id == "ou_X"
    end

    test "emits event with error type on conflict", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        bob:
          feishu_ids:
            - ou_X
        linyilun:
          feishu_ids: []
      """)

      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :slash, :feishu, :self_bind]])

      assert {:error, %{"type" => "feishu_id_in_use"}} =
               SelfBind.execute(%{
                 "args" => %{"name" => "linyilun", "principal_id" => "ou_X"}
               })

      assert_receive {[:esr, :slash, :feishu, :self_bind], ^ref, _measurements, metadata}
      assert metadata.result == "feishu_id_in_use"
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_bind_test.exs)`
Expected: **2 failures** — `assert_receive` times out (no event emitted).

- [ ] **Step 3: Add telemetry emission in SelfBind**

Replace `runtime/lib/esr/plugins/feishu/commands/self_bind.ex` entirely:

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfBind do
  @moduledoc """
  Slash-only self-bind wrapper for `/feishu:bind`. Reads the caller's
  Feishu open_id from the envelope-injected `args["principal_id"]`,
  delegates to BindUser.

  Any args key not in `@allowed_keys` is rejected as `invalid_args` —
  this closes the attack-injection path (caller passing
  `feishu_user_id=ou_VICTIM`) and gives clear feedback for typos.

  Emits `[:esr, :slash, :feishu, :self_bind]` telemetry on every
  invocation; metadata carries `name`, `principal_id`, and `result`
  (`:ok` or the error type string).

  Admin-代-bind takes the BindUser path directly via the `feishu_bind`
  internal_kind (CLI submit, gated by `feishu/user-bind`).
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.BindUser

  @allowed_keys ~w(name principal_id chat_id app_id thread_id)

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) when is_map(args) do
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

- [ ] **Step 4: Run the full test file**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_bind_test.exs)`
Expected: **11 tests, 0 failures.**

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/commands/self_bind.ex runtime/test/esr/plugins/feishu/commands/self_bind_test.exs
git commit -m "$(cat <<'EOF'
feat(feishu): SelfBind emits [:esr, :slash, :feishu, :self_bind] telemetry

Bind events emit metadata {name, principal_id, result} on every
invocation. result is :ok on success or the error type string for
audit-trail purposes (spec § 4.5 + § 7.3).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: SelfUnbind — golden path + lookup-then-delegate

**Files:**
- Create: `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex`
- Create: `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs`

- [ ] **Step 1: Write the failing test (golden path)**

Create `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs`:

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfUnbindTest do
  use ExUnit.Case, async: false

  alias Esr.Plugins.Feishu.Commands.SelfUnbind

  setup do
    tmp = Path.join(System.tmp_dir!(), "feishu_self_unbind_#{:rand.uniform(1_000_000)}")
    inst_dir = Path.join(tmp, "default")
    File.mkdir_p!(inst_dir)

    prev_home = System.get_env("ESRD_HOME")
    prev_inst = System.get_env("ESR_INSTANCE")
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    on_exit(fn ->
      if prev_home, do: System.put_env("ESRD_HOME", prev_home), else: System.delete_env("ESRD_HOME")
      if prev_inst, do: System.put_env("ESR_INSTANCE", prev_inst), else: System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)

    {:ok, inst_dir: inst_dir}
  end

  defp write_users_yaml(inst_dir, content), do: File.write!(Path.join(inst_dir, "users.yaml"), content)
  defp read_users_yaml(inst_dir), do: YamlElixir.read_from_file!(Path.join(inst_dir, "users.yaml"))

  describe "golden path" do
    test "unbinds caller ou_xxx from the user that owns it", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)

      assert {:ok, %{"text" => text}} =
               SelfUnbind.execute(%{"args" => %{"principal_id" => "ou_X"}})

      assert text =~ "unbound"
      assert text =~ "linyilun"

      assert %{"users" => %{"linyilun" => %{"feishu_ids" => []}}} =
               read_users_yaml(inst_dir)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs)`
Expected: **FAIL** — `Esr.Plugins.Feishu.Commands.SelfUnbind is not available`.

- [ ] **Step 3: Create the SelfUnbind module**

Create `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex`:

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
      nil -> {:ok, %{"text" => "#{p} is not bound to any esr user"}}
      name -> UnbindUser.execute(%{"args" => %{"name" => name, "feishu_user_id" => p}})
    end
  end

  def execute(_) do
    {:error, %{
      "type" => "invalid_args",
      "message" => "/feishu:unbind requires an envelope-injected principal_id"
    }}
  end

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

- [ ] **Step 4: Run the test to verify it passes**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs)`
Expected: **1 test, 0 failures.**

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/commands/self_unbind.ex runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs
git commit -m "$(cat <<'EOF'
feat(feishu): SelfUnbind wrapper — lookup owner then delegate to UnbindUser

First slice of /feishu:unbind plugin self-unbind support. Reads
caller's ou_xxx from envelope, finds the owning esr user, delegates
to the existing admin UnbindUser command. Whitelist + telemetry
land in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: SelfUnbind — idempotent / partial removal / invalid args / write fail

**Files:**
- Modify: `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs`

- [ ] **Step 1: Add the new cases**

Append to `self_unbind_test.exs`:

```elixir
  describe "delegation" do
    test "idempotent — caller ou_xxx not bound to anyone returns ok", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)
      before = File.read!(Path.join(inst_dir, "users.yaml"))

      assert {:ok, %{"text" => text}} =
               SelfUnbind.execute(%{"args" => %{"principal_id" => "ou_X"}})

      assert text =~ "not bound"
      assert before == File.read!(Path.join(inst_dir, "users.yaml"))
    end

    test "partial removal — only the caller's ou_xxx is removed", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
            - ou_Y
      """)

      assert {:ok, _} =
               SelfUnbind.execute(%{"args" => %{"principal_id" => "ou_X"}})

      assert %{"users" => %{"linyilun" => %{"feishu_ids" => ["ou_Y"]}}} =
               read_users_yaml(inst_dir)
    end
  end

  describe "invalid input" do
    test "missing principal_id produces invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               SelfUnbind.execute(%{"args" => %{}})
    end
  end

  describe "yaml write failure" do
    test "returns write_failed when users.yaml parent is read-only", %{inst_dir: inst_dir} do
      # Skip on root / EUID==0 — chmod 0o555 is bypassed for root, so the
      # write would succeed and the assertion would fail. Common in CI
      # containers running as root.
      case System.cmd("id", ["-u"]) do
        {"0\n", 0} ->
          IO.puts("\n  [skipped on root: chmod 0o555 is bypassed for EUID==0]")

        {_, 0} ->
          write_users_yaml(inst_dir, """
          users:
            linyilun:
              feishu_ids:
                - ou_X
          """)

          File.chmod!(inst_dir, 0o555)

          try do
            assert {:error, %{"type" => "write_failed"}} =
                     SelfUnbind.execute(%{"args" => %{"principal_id" => "ou_X"}})
          after
            File.chmod!(inst_dir, 0o755)
          end
      end
    end
  end
```

- [ ] **Step 2: Run the test file**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs)`
Expected: **5 tests, 0 failures** (1 from Task 6 + 4 new). All four delegation cases reuse already-implemented logic.

If `write_failed` test does not produce that error type, inspect `runtime/lib/esr/plugins/feishu/commands/unbind_user.ex` for its actual error shape on `Yaml.Writer` failure, and adjust the assertion accordingly. The spec lists `write_failed` as the existing UnbindUser type.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs
git commit -m "$(cat <<'EOF'
test(feishu): SelfUnbind delegation cases — idempotent, partial removal, invalid args, write-fail

Verifies SelfUnbind correctly forwards UnbindUser's existing
behaviors through the slash-driven path. No production change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: SelfUnbind — strict-args whitelist (`@allowed_keys`)

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex`
- Modify: `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs`

- [ ] **Step 1: Add failing whitelist tests**

Append to `self_unbind_test.exs`:

```elixir
  describe "strict-args whitelist" do
    test "rejects user-supplied feishu_user_id=", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)
      before = File.read!(Path.join(inst_dir, "users.yaml"))

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SelfUnbind.execute(%{
                 "args" => %{"principal_id" => "ou_X", "feishu_user_id" => "ou_OTHER"}
               })

      assert msg =~ "feishu_user_id"
      assert before == File.read!(Path.join(inst_dir, "users.yaml"))
    end

    test "rejects user-supplied name= (cross-account unbind not allowed)", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SelfUnbind.execute(%{
                 "args" => %{"principal_id" => "ou_X", "name" => "linyilun"}
               })

      assert msg =~ "name"
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs)`
Expected: **2 failures** — first one accidentally unbinds (returns `:ok`), second one... actually depends. Without whitelist, the first test would reach `do_unbind/1` with `principal_id=ou_X`, find linyilun, and unbind successfully (returns `:ok`, FAIL on the assertion). The second one ditto.

- [ ] **Step 3: Refactor SelfUnbind to add whitelist**

Replace `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex` entirely:

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfUnbind do
  @moduledoc """
  Slash-only self-unbind wrapper for `/feishu:unbind`. Looks up which
  esr user currently owns the caller's `ou_xxx` and delegates to
  UnbindUser. Idempotent if the caller has no binding.

  Any args key not in `@allowed_keys` is rejected as `invalid_args`
  (mirrors SelfBind contract). The slash declares `args: []`, so
  user-supplied keys (incl. `name=` and `feishu_user_id=`) are
  always rejected; envelope-injected keys (principal_id, chat_id,
  app_id, thread_id) are allowed through.
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.UnbindUser

  @allowed_keys ~w(principal_id chat_id app_id thread_id)

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) when is_map(args) do
    case Map.keys(args) -- @allowed_keys do
      [] -> do_unbind(args)
      extras -> reject_extras(extras)
    end
  end

  def execute(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind requires args (envelope must inject principal_id)"}}

  defp do_unbind(%{"principal_id" => p}) when is_binary(p) and p != "" do
    case lookup_owner(p) do
      nil -> {:ok, %{"text" => "#{p} is not bound to any esr user"}}
      name -> UnbindUser.execute(%{"args" => %{"name" => name, "feishu_user_id" => p}})
    end
  end

  defp do_unbind(_), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind requires an envelope-injected principal_id"}}

  defp reject_extras(extras), do: {:error, %{"type" => "invalid_args", "message" =>
    "/feishu:unbind does not accept: #{Enum.join(extras, ", ")}"}}

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

- [ ] **Step 4: Run the full test file**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs)`
Expected: **7 tests, 0 failures.**

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/commands/self_unbind.ex runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs
git commit -m "$(cat <<'EOF'
feat(feishu): SelfUnbind strict-args (@allowed_keys whitelist)

Reject user-supplied name= and feishu_user_id= and any other
unknown keys. /feishu:unbind only operates on caller's own ou_xxx.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: SelfUnbind — race-remap (`user_not_found` → idempotent ok)

**Why:** `lookup_owner/1` and `UnbindUser.execute/1` each read `users.yaml`. A concurrent admin-代-unbind landing between the two reads makes UnbindUser see no entry → returns `{:error, %{"type" => "user_not_found"}}`. From the self-unbind caller's perspective the binding IS gone, so surfacing "user not found" is confusing. Catch and remap to idempotent `:ok`. Spec § 4.4 + § 7.2.

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex`
- Modify: `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs`

- [ ] **Step 1: Add a failing test for the race-remap**

Append to `self_unbind_test.exs`:

```elixir
  describe "race-remap (spec § 7.2)" do
    # Simulate the race deterministically by setting up a yaml shape
    # where lookup_owner returns "linyilun" but the on-disk yaml seen
    # by UnbindUser has linyilun's feishu_ids already missing ou_X
    # (as if a concurrent admin unbind landed between the two reads).
    #
    # Easiest reproduction: lookup_owner reads YAML once; UnbindUser
    # re-reads it. We rewrite users.yaml between the two by stubbing
    # lookup_owner via :meck or by exposing it as public for testing.
    test "user_not_found from delegated UnbindUser is remapped to idempotent :ok", %{inst_dir: inst_dir} do
      # Set up users.yaml without ou_X anywhere (so UnbindUser sees nothing)
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      # But lookup_owner needs to "find" linyilun. Use :meck to override.
      :meck.new(Esr.Plugins.Feishu.Commands.SelfUnbind, [:passthrough])
      :meck.expect(Esr.Plugins.Feishu.Commands.SelfUnbind, :lookup_owner, fn _ -> "linyilun" end)

      try do
        assert {:ok, %{"text" => text}} =
                 SelfUnbind.execute(%{"args" => %{"principal_id" => "ou_X"}})

        assert text =~ "no longer bound"
      after
        :meck.unload(Esr.Plugins.Feishu.Commands.SelfUnbind)
      end
    end
  end
```

(Pre-req: `:meck` must be in `runtime/mix.exs` test deps. If it isn't, add `{:meck, "~> 0.9", only: :test}` to `deps/0` in mix.exs and run `mix deps.get` before this step. Verify by running `mix deps | grep meck`.)

Alternative (no meck): refactor `SelfUnbind` to take an injected `lookup_owner_fn` argument with a default — but that complicates the public API. The meck approach keeps the production module unchanged.

- [ ] **Step 2: Run the test to verify it fails**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs --only describe:"race-remap")`
Expected: **FAIL** — without remap, SelfUnbind returns `{:error, %{"type" => "user_not_found"}}`. The test asserts `:ok` with `no longer bound` text.

- [ ] **Step 3: Add the remap to SelfUnbind**

In `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex`, find `do_unbind/1` and replace it:

```elixir
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
```

Also expose `lookup_owner/1` as a public function so `:meck` can patch it (rev-3 test exposure):

```elixir
  # Was: defp lookup_owner(fid) do ... end
  # Now: def lookup_owner(fid) do ... end  (test-exposed; keep doc as @doc false)
  @doc false
  def lookup_owner(fid) do
    ...
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs --only describe:"race-remap")`
Expected: PASS.

- [ ] **Step 5: Run the full self_unbind_test file — regression check**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs)`
Expected: all green (8 prior tests + 1 new race-remap = 9 total at this stage).

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/commands/self_unbind.ex runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs runtime/mix.exs
git commit -m "$(cat <<'EOF'
feat(feishu): SelfUnbind race-remap user_not_found → idempotent ok

A concurrent admin feishu_unbind between lookup_owner and the
delegated UnbindUser.execute can leave UnbindUser seeing nothing
even though lookup_owner found the owning user. From the self-unbind
caller's perspective this is "no longer bound" — collapse to ok with
a clear message instead of surfacing user_not_found.

Spec 2026-05-09-feishu-slash-bind-design.md § 4.4 + § 7.2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: SelfUnbind — telemetry events

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex`
- Modify: `runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs`

- [ ] **Step 1: Add failing telemetry tests**

Append to `self_unbind_test.exs`:

```elixir
  describe "telemetry" do
    test "emits [:esr, :slash, :feishu, :self_unbind] on success", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)

      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :slash, :feishu, :self_unbind]])

      assert {:ok, _} = SelfUnbind.execute(%{"args" => %{"principal_id" => "ou_X"}})

      assert_receive {[:esr, :slash, :feishu, :self_unbind], ^ref, _measurements, metadata}
      assert metadata.result == :ok
      assert metadata.principal_id == "ou_X"
    end

    test "emits event with result :ok on idempotent (not-bound) case", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :slash, :feishu, :self_unbind]])

      assert {:ok, _} = SelfUnbind.execute(%{"args" => %{"principal_id" => "ou_X"}})

      assert_receive {[:esr, :slash, :feishu, :self_unbind], ^ref, _measurements, metadata}
      assert metadata.result == :ok
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs)`
Expected: **2 failures** — `assert_receive` times out.

- [ ] **Step 3: Add telemetry emission**

Replace `runtime/lib/esr/plugins/feishu/commands/self_unbind.ex` entirely:

```elixir
defmodule Esr.Plugins.Feishu.Commands.SelfUnbind do
  @moduledoc """
  Slash-only self-unbind wrapper for `/feishu:unbind`. Looks up which
  esr user currently owns the caller's `ou_xxx` and delegates to
  UnbindUser. Idempotent if the caller has no binding.

  Any args key not in `@allowed_keys` is rejected as `invalid_args`
  (mirrors SelfBind contract). The slash declares `args: []`, so
  user-supplied keys (incl. `name=` and `feishu_user_id=`) are
  always rejected; envelope-injected keys (principal_id, chat_id,
  app_id, thread_id) are allowed through.

  Emits `[:esr, :slash, :feishu, :self_unbind]` telemetry on every
  invocation; metadata carries `principal_id` and `result`.
  """

  @behaviour Esr.Role.Control
  alias Esr.Plugins.Feishu.Commands.UnbindUser

  @allowed_keys ~w(principal_id chat_id app_id thread_id)

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => args}) when is_map(args) do
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
      name -> UnbindUser.execute(%{"args" => %{"name" => name, "feishu_user_id" => p}})
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

- [ ] **Step 4: Run the full test file**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/self_unbind_test.exs)`
Expected: **10 tests, 0 failures** (8 from Tasks 6-8 + 1 race-remap from Task 9 + 2 telemetry).

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/commands/self_unbind.ex runtime/test/esr/plugins/feishu/commands/self_unbind_test.exs
git commit -m "$(cat <<'EOF'
feat(feishu): SelfUnbind emits [:esr, :slash, :feishu, :self_unbind] telemetry

Unbind events emit metadata {principal_id, result} on every
invocation. Result is :ok for both successful unbind and idempotent
no-op cases — both are valid outcomes and need audit trail.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Plugin manifest registration + registry tests

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml`
- Modify: `runtime/test/esr/plugins/feishu/commands/migration_test.exs`

- [ ] **Step 0: Pre-check `Registry.lookup/1` return shape (IEx)**

The current feishu manifest has `slashes: {}`, so the migration_test.exs only exercises `command_module_for/1` (returns just a module). The new tests in this task will assert against `Registry.lookup/1`, which returns `{:ok, route}` — but we don't know if `route` map has atom keys (`%{kind: ...}`) or string keys (`%{"kind" => ...}`) without verifying. **Verify before writing assertions** — pick any existing slash that already works (e.g. `/help`):

```bash
(cd runtime && iex -S mix)
```

In the IEx prompt:

```elixir
Esr.Resource.SlashRoute.Registry.lookup("/help")
# Expected output shape (one of):
#   {:ok, %{kind: "help", command_module: Esr.Commands.Help, ...}}    # atom keys
#   {:ok, %{"kind" => "help", "command_module" => "Esr.Commands.Help", ...}}  # string keys
System.halt(0)
```

Note the key shape. The Step 1 assertions below assume **atom keys**; if you see string keys, adjust the test code to match (`%{"kind" => "feishu_self_bind", "command_module" => Esr.Plugins.Feishu.Commands.SelfBind}` and similarly for `/feishu:unbind`).

- [ ] **Step 1: Add failing registry tests**

Modify `runtime/test/esr/plugins/feishu/commands/migration_test.exs`. Append inside the existing `describe "post-migration kind dispatch (audit #6 rev-3)" do` block, before the closing `end`:

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

- [ ] **Step 2: Run the tests to verify they fail**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/migration_test.exs)`
Expected: **4 failures** — registry returns `:not_found` because manifest does not yet declare these kinds/slashes.

- [ ] **Step 3: Update the manifest**

Edit `runtime/lib/esr/plugins/feishu/manifest.yaml`. Find the `slash_routes:` block (around line 71–83) and replace it with:

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
      feishu_notify:
        permission: "feishu/notify-send"
        command_module: "Esr.Plugins.Feishu.Commands.Notify"
      feishu_bind:
        permission: "feishu/user-bind"
        command_module: "Esr.Plugins.Feishu.Commands.BindUser"
      feishu_unbind:
        permission: "feishu/user-bind"
        command_module: "Esr.Plugins.Feishu.Commands.UnbindUser"
      feishu_self_bind:
        permission: null
        command_module: "Esr.Plugins.Feishu.Commands.SelfBind"
      feishu_self_unbind:
        permission: null
        command_module: "Esr.Plugins.Feishu.Commands.SelfUnbind"
```

The structural rule (per `slash-routes.default.yaml:765-767`): every kind name in `slashes:` MUST also have an `internal_kinds:` row with matching `permission` and `command_module`, otherwise registry rebuild silently drops one (registry_test.exs:533 regression test verifies this).

- [ ] **Step 4: Run the migration test file**

Run: `(cd runtime && mix test test/esr/plugins/feishu/commands/migration_test.exs)`
Expected: **8 tests, 0 failures** (4 pre-existing + 4 new).

- [ ] **Step 5: Run the entire feishu test suite — regression check**

Run: `(cd runtime && mix test test/esr/plugins/feishu/)`
Expected: **all tests pass.** Specifically watch for:
- The plugin overlay tests (`plugin_test.exs`, `bootstrap_test.exs`) — these load the manifest and must accept the expanded `slash_routes:` block.
- `feishu_chat_proxy_test.exs` — should be unaffected (doesn't touch slash routes).

If a pre-existing test fails: most likely cause is the manifest YAML indentation — re-check Step 3 against the existing structure in `manifest.yaml` (the `declares:` block uses 2-space indent inside `slash_routes:`).

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/manifest.yaml runtime/test/esr/plugins/feishu/commands/migration_test.exs
git commit -m "$(cat <<'EOF'
feat(feishu): register /feishu:bind + /feishu:unbind in plugin manifest

Adds the two new slashes to feishu plugin's slash_routes block, with
matching internal_kinds rows for the file-queue admin path. Registry
tests verify both slash text and kind name resolve to the right
command modules.

Permission: null on both — chat-membership trust, justified by the
pre-existing user_add admin gate (caller's name= must already exist
in users.yaml). Spec § 3.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Final verification — full feishu suite + spec self-check

**Files:** none modified — verification only.

- [ ] **Step 1: Run the entire feishu plugin test suite**

Run: `(cd runtime && mix test test/esr/plugins/feishu/ --trace)`
Expected: all green. The `--trace` flag prints test names so you can verify the new files (`self_bind_test.exs`, `self_unbind_test.exs`) produced expected counts (11 + 10 = 21 new tests in feishu/commands/; 4 new in `migration_test.exs`; 1 new in `slash_handler_test.exs` from Task 1; **26 total new tests**).

- [ ] **Step 2: Run the full runtime test suite — sanity check for unrelated regressions**

Run: `(cd runtime && mix test)`
Expected: pass, modulo any pre-existing flakes documented at [`docs/operations/known-flakes.md`](../../operations/known-flakes.md). New test files should not introduce any new failures or flakes.

If a pre-existing test starts failing because of these changes: most likely cause is `manifest.yaml` indentation breaking `Esr.Plugin.Loader`. Re-check the YAML structure.

- [ ] **Step 3: Run a manual sanity check via mix shell**

```bash
(cd runtime && iex -S mix)
```

In the IEx prompt:

```elixir
# Verify the registry resolves the new slashes:
Esr.Resource.SlashRoute.Registry.lookup("/feishu:bind")
# Expected: {:ok, %{kind: "feishu_self_bind", command_module: Esr.Plugins.Feishu.Commands.SelfBind, ...}}

Esr.Resource.SlashRoute.Registry.lookup("/feishu:unbind")
# Expected: {:ok, %{kind: "feishu_self_unbind", command_module: Esr.Plugins.Feishu.Commands.SelfUnbind, ...}}

# Quick smoke of SelfBind invalid-args path (no users.yaml needed):
Esr.Plugins.Feishu.Commands.SelfBind.execute(%{"args" => %{"random" => "x"}})
# Expected: {:error, %{"type" => "invalid_args", "message" => "/feishu:bind does not accept: random"}}

System.halt(0)
```

- [ ] **Step 4: Verify spec coverage**

Open [`docs/superpowers/specs/2026-05-09-feishu-slash-bind-design.md`](../specs/2026-05-09-feishu-slash-bind-design.md) and skim each section. Cross-check:

- § 3.1 file structure → matches what was created/modified.
- § 3.2 manifest diff → matches Task 11 step 3 verbatim.
- § 4.3 / § 4.4 SelfBind / SelfUnbind code → matches the modules at end of Task 5 / Task 10.
- § 4.5 telemetry events → both emitted, both tested (Task 5 + Task 10).
- § 5.1 / § 5.2 error semantics decision tables → all rows have at least one corresponding test.
- § 6.1 / § 6.2 / § 6.3 test cases → all 11 + 10 + 4 cases implemented (rev-3 added race-remap to § 6.2 → 10 cases there).
- § 7.2 race comment → present in `self_unbind.ex:lookup_owner/1`.

- [ ] **Step 5: No commit needed — verification task only**

If everything checks out, the implementation is complete. Optionally `git log --oneline -10` to review the commit sequence.

---

## Self-review notes (skill checklist)

**1. Spec coverage:**
- § 3.1 files — ✅ Tasks 1-9 touch every listed file.
- § 3.2 manifest — ✅ Task 11 step 3.
- § 3.4 permission model — ✅ implicit (`permission: null` in Task 11 manifest).
- § 4.1–§ 4.4 data flow + module bodies — ✅ Tasks 1-8.
- § 4.5 telemetry — ✅ Tasks 4 + 8.
- § 5.1–§ 5.2 error semantics — ✅ test cases in Tasks 1-8 cover every row.
- § 6.1–§ 6.3 test plan — ✅ tests written exactly as specified.
- § 6.5 stability constraints — ✅ `async: false` everywhere, no FSEvents dependence.
- § 7.2 race comment + remap — ✅ inline in Task 6 step 3; remap added in Task 9; tested via Task 9 + Task 10.

**2. Placeholder scan:** none. Every step has runnable code or exact commands.

**3. Type consistency:**
- `@allowed_keys` lists checked across SelfBind (Task 4) and SelfUnbind (Task 8) — different key sets are intentional (SelfBind takes user-supplied `name`, SelfUnbind takes none).
- `result_tag/1` helper has identical clauses in both modules — intentional duplication; eliminated via Meta in future per spec § 8.
- Telemetry event names spelled identically in tests, code, and spec: `[:esr, :slash, :feishu, :self_bind]` and `[:esr, :slash, :feishu, :self_unbind]`.
- `feishu_self_bind` / `feishu_self_unbind` kind names match across manifest, command_module assertions, and test labels.
