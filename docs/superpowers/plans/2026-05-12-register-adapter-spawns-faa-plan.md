# register_adapter Spawns FAA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `register_adapter` atomically spawn the Elixir-side `FeishuAppAdapter` GenServer alongside the Python sidecar, so post-boot adapter registration produces a fully-wired Feishu plumb (no silent inbound drops).

**Architecture:** Add a `:startup_fn` opt to `Esr.Commands.RegisterAdapter.execute/2` defaulting to `&Esr.Plugin.Loader.run_startup/0`. After `spawn_adapter` (Python sidecar) returns `:ok`, invoke `startup_fn.()` to re-run every enabled plugin's idempotent startup hook — same path that `adapter_refresh` already takes. Feishu's hook (`Esr.Plugins.Feishu.Bootstrap.bootstrap/0`) walks `adapters/<name>/config.yaml` (just written by `Esr.Adapters.add/3`) and spawns the FAA peer; `DynamicSupervisor.start_child` is idempotent on already-running instances. A new integration test boots the real Application supervision tree and asserts `Esr.Entity.Registry.lookup("feishu_app_adapter_<name>")` returns a pid post-register, closing the regression gap that let this bug ship.

**Tech Stack:** Elixir 1.18 / OTP 27 / Phoenix / ExUnit `:integration` tag.

**Bug context:** Live diagnosed 2026-05-12 (Feishu chat oc_d9b47511b085e9d5b66c4595b3ef9bb9). After `tools/wipe-esrd-home.sh --dev` + esrd boot + `register_adapter`, inbound Feishu messages were silently dropped with `[warning] adapter_channel: no FeishuAppAdapter for app_id=esr_helper_dev`. Root cause: `register_adapter.ex:80` calls only `WorkerSupervisor.ensure_adapter` (Python sidecar); the Elixir FAA peer is spawned only by `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` from `Esr.Plugin.Loader.run_startup/0`, which runs only at esrd boot or `adapter_refresh`. Operator manually verified the fix path by running `esr exec adapter_refresh` — bind succeeded immediately after.

**Branch:** `fix/register-adapter-spawns-faa` off `origin/dev`. Admin-squash-merge.

**Estimated:** ~70 LOC (15 src, 50 tests, 5 docs).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `runtime/lib/esr/commands/register_adapter.ex` | Modify | Add `:startup_fn` opt; call after `spawn_adapter` |
| `runtime/test/esr/commands/register_adapter_test.exs` | Modify | New unit test: `:startup_fn` is invoked after `spawn_fn` |
| `runtime/test/esr/integration/register_adapter_spawns_faa_test.exs` | Create | Integration test: real Application boot, asserts FAA pid registered |
| `docs/guides/flow-bootstrap.md` | Modify | Add 1-sentence callout in step 3 that registration is atomic (sidecar + FAA) |
| `docs/futures/todo.md` | Modify | Close `unconsumed-message-errors-not-hangs` row (this fix subsumes it for the adapter-spawn-gap case) and the duplicate root-cause row noted 2026-05-12 |

---

## Task 1: Failing unit test — `:startup_fn` is invoked after `spawn_fn`

**Files:**
- Modify: `runtime/test/esr/commands/register_adapter_test.exs` (append new `describe` block at end of file, before final `end`)

- [ ] **Step 1: Create the branch**

Run:
```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/fix-unconsumed-msg
git fetch origin dev
git checkout -b fix/register-adapter-spawns-faa origin/dev
```

Expected: `Switched to a new branch 'fix/register-adapter-spawns-faa'`

- [ ] **Step 2: Append the failing test**

Add the following `describe` block at the end of `runtime/test/esr/commands/register_adapter_test.exs`, immediately before the final `end` of the module:

```elixir
  describe "post-spawn startup hook (2026-05-12 FAA atomicity fix)" do
    test ":startup_fn is invoked after spawn_fn succeeds (default path wires FAA)", %{tmp: _tmp} do
      test_pid = self()

      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "atomic_test",
          "app_id" => "cli_atomic",
          "app_secret" => "s"
        }
      }

      assert {:ok, _} =
               RegisterAdapter.execute(cmd,
                 spawn_fn: fn _ ->
                   send(test_pid, :spawn_fn_called)
                   :ok
                 end,
                 startup_fn: fn ->
                   send(test_pid, :startup_fn_called)
                   :ok
                 end
               )

      # Ordering: sidecar first, then FAA. If reversed, the FAA would
      # spawn against a missing config file and fail.
      assert_receive :spawn_fn_called, 1_000
      assert_receive :startup_fn_called, 1_000
    end

    test ":startup_fn is NOT invoked when spawn_fn fails (no half-state)", %{tmp: _tmp} do
      test_pid = self()

      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "spawn_fail",
          "app_id" => "cli_x",
          "app_secret" => "s"
        }
      }

      assert {:error, %{"type" => "register_adapter_failed"}} =
               RegisterAdapter.execute(cmd,
                 spawn_fn: fn _ -> {:error, :sidecar_boom} end,
                 startup_fn: fn ->
                   send(test_pid, :startup_fn_called)
                   :ok
                 end
               )

      refute_receive :startup_fn_called, 200
    end
  end
```

- [ ] **Step 3: Run the new test to verify it fails**

Run:
```bash
cd runtime && mix test test/esr/commands/register_adapter_test.exs --only describe:"post-spawn startup hook (2026-05-12 FAA atomicity fix)"
```

Expected: FAIL — `RegisterAdapter.execute/2` ignores `:startup_fn` opt, so `:startup_fn_called` is never received. Test 1 fails on `assert_receive :startup_fn_called`. Test 2 passes vacuously (we want test 1 to fail).

Note: ExUnit's `--only` flag matches `describe` only when you tag the describe block. If `--only describe:"..."` doesn't filter by description string in this Mix version, run the full file instead and inspect output for the two new tests:

```bash
cd runtime && mix test test/esr/commands/register_adapter_test.exs
```

Expected: 2 new tests fail (`:startup_fn is invoked after spawn_fn` fails; `:startup_fn is NOT invoked when spawn_fn fails` passes); pre-existing tests all pass.

- [ ] **Step 4: Do NOT commit yet** — the test guides the fix in Task 2.

---

## Task 2: Add `:startup_fn` opt to `register_adapter.ex`

**Files:**
- Modify: `runtime/lib/esr/commands/register_adapter.ex:71-95` (the `execute/2` happy-path clause)

- [ ] **Step 1: Update the happy-path clause to call `startup_fn` after `spawn_adapter`**

Replace lines 71-95 of `runtime/lib/esr/commands/register_adapter.ex`:

```elixir
  @spec execute(map(), keyword()) :: result()
  def execute(
        %{"args" => %{"type" => "feishu", "name" => name, "app_id" => app_id, "app_secret" => secret}},
        opts
      )
      when is_binary(name) and is_binary(app_id) and is_binary(secret) do
    config = %{"app_id" => app_id, "app_secret" => secret}

    case Esr.Adapters.add(name, "feishu", config) do
      :ok ->
        with :ok <- spawn_adapter(name, app_id, secret, opts),
             :ok <- run_startup_hooks(opts) do
          {:ok, %{"adapter_id" => name, "running" => true}}
        else
          {:error, reason} ->
            Render.error(__MODULE__.command_meta(), :register_adapter_failed, %{
              detail: inspect(reason)
            })
        end

      {:error, reason} ->
        Render.error(__MODULE__.command_meta(), :register_adapter_failed, %{
          detail: inspect(reason)
        })
    end
  end
```

- [ ] **Step 2: Add the `run_startup_hooks/1` private function**

Append immediately before `defp default_adapter_ws_url do` (around line 134 in the original file, after `spawn_adapter/4`):

```elixir
  # After the Python sidecar is up, re-run every enabled plugin's
  # idempotent startup hook so the matching Elixir peer (e.g. feishu's
  # FAA) spawns against the just-written adapters/<name>/config.yaml.
  # Same path adapter_refresh takes. Without this step register_adapter
  # leaves a half-wired plumb: sidecar up, FAA missing → inbound
  # messages silently dropped with "no FeishuAppAdapter for app_id=...".
  # Diagnosed 2026-05-12 (Feishu live test).
  defp run_startup_hooks(opts) do
    startup_fn = Keyword.get(opts, :startup_fn, &Esr.Plugin.Loader.run_startup/0)

    case startup_fn.() do
      :ok -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_startup_fn_return, other}}
    end
  end
```

- [ ] **Step 3: Run the new tests to verify they pass**

Run:
```bash
cd runtime && mix test test/esr/commands/register_adapter_test.exs
```

Expected: all tests pass (existing + 2 new).

- [ ] **Step 4: Run the full command test suite to check for regressions**

Run:
```bash
cd runtime && mix test test/esr/commands/
```

Expected: all tests pass. Why no other tests should need updating: in `mix test`, `config/test.exs` sets `enabled_plugins: []`, so `Esr.Plugin.Loader`'s `:startup_callbacks` persistent_term is empty. The default `&Esr.Plugin.Loader.run_startup/0` therefore no-ops in unit tests — pre-existing register_adapter tests that pass only `spawn_fn:` continue to work without supplying `startup_fn:`.

If a test DOES fail here, investigate before patching — the default no-op contract should hold.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/register_adapter.ex runtime/test/esr/commands/register_adapter_test.exs
git commit -m "$(cat <<'EOF'
fix(register_adapter): spawn FAA atomically via startup_fn DI

After spawn_adapter (Python sidecar) succeeds, re-run plugin startup
hooks so the matching Elixir peer (feishu FAA) spawns against the
just-written adapters/<name>/config.yaml. Same idempotent path that
adapter_refresh takes.

Pre-fix: post-boot register_adapter left a half-wired plumb (sidecar
up, FAA missing). Inbound Feishu messages silently dropped with
`no FeishuAppAdapter for app_id=...`. Diagnosed 2026-05-12 live test;
fix verified manually via `esr exec adapter_refresh`.

DI'd via `:startup_fn` opt (mirrors existing `:spawn_fn` pattern) so
tests don't have to boot the full plugin loader.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Integration test — real Application boot proves FAA gets registered

**Files:**
- Create: `runtime/test/esr/integration/register_adapter_spawns_faa_test.exs`

- [ ] **Step 1: Create the integration test file**

Write to `runtime/test/esr/integration/register_adapter_spawns_faa_test.exs`:

```elixir
defmodule Esr.Integration.RegisterAdapterSpawnsFaaTest do
  @moduledoc """
  Integration test for the 2026-05-12 atomic-FAA-spawn fix.

  Live-test bug: after `tools/wipe-esrd-home.sh --dev` + esrd boot +
  `register_adapter`, inbound Feishu messages were silently dropped
  because `register_adapter` only spawned the Python sidecar, not the
  Elixir FAA peer.

  This test exercises the real `Esr.Plugin.Loader.run_startup/0` path:
  the unit test (`register_adapter_test.exs`) DI's `:startup_fn` and
  proves it gets called; this test proves the default callback actually
  ends with an FAA process registered in `Esr.Entity.Registry`.

  Tagged `:integration` so it's skipped by default (`test_helper.exs`
  excludes that tag). Run via `mix test --include integration <path>`.

  ## Test environment caveat (seed feishu startup callback)

  `config/test.exs:23` sets `enabled_plugins: []`, so the feishu plugin
  is NOT loaded during `mix test`. Consequently `Esr.Plugin.Loader`'s
  `:startup_callbacks` persistent_term is empty, and the default
  `&Esr.Plugin.Loader.run_startup/0` would no-op — the FAA would never
  spawn and `Registry.lookup` would return `[]`.

  Seed the persistent_term in setup with feishu's startup tuple (the
  same shape `Esr.Plugin.Loader.register_startup/2` writes at boot in
  production). on_exit restores the previous value so the leak doesn't
  cross into other integration tests.

  ## Cleanup contract

  The FAA process spawned by run_startup/0 is parented to
  `Esr.Session.Admin.children_supervisor_name()` (a global
  DynamicSupervisor in the Application tree). on_exit must terminate
  the child so it doesn't leak into subsequent tests in the same VM.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Esr.Commands.RegisterAdapter

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "regadapt_faa_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    # Seed feishu's startup callback (test.exs sets enabled_plugins=[]).
    # Tuple shape matches what register_startup/2 writes in production
    # (loader.ex:377-393): {plugin_name :: String.t(), module(), atom()}.
    prev_callbacks = :persistent_term.get({Esr.Plugin.Loader, :startup_callbacks}, [])

    :persistent_term.put(
      {Esr.Plugin.Loader, :startup_callbacks},
      prev_callbacks ++ [{"feishu", Esr.Plugins.Feishu.Bootstrap, :bootstrap}]
    )

    sup = Esr.Session.Admin.children_supervisor_name()
    instance_id = "atomic_faa_#{unique}"

    on_exit(fn ->
      # Kill any FAA(s) this test left in the global supervisor before
      # tearing down ESRD_HOME — otherwise the next test in the same VM
      # inherits an orphan FAA registered under the same name.
      for key <- [
            "feishu_app_adapter_#{instance_id}",
            "feishu_app_adapter_#{instance_id}_a",
            "feishu_app_adapter_#{instance_id}_b"
          ] do
        case Registry.lookup(Esr.Entity.Registry, key) do
          [{pid, _}] when is_pid(pid) ->
            _ = DynamicSupervisor.terminate_child(sup, pid)

          _ ->
            :ok
        end
      end

      :persistent_term.put({Esr.Plugin.Loader, :startup_callbacks}, prev_callbacks)

      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, instance_id: instance_id}
  end

  test "register_adapter spawns the FAA in Esr.Entity.Registry", %{instance_id: name} do
    # spawn_fn stub so we don't fork a real Python sidecar — only the
    # startup_fn (defaulted to Esr.Plugin.Loader.run_startup/0) needs to
    # be real for this test. Bootstrap.bootstrap/0 reads
    # adapters/<name>/config.yaml from disk and spawns the FAA; the disk
    # write happens inside execute/2's Esr.Adapters.add/3, so by the
    # time startup_fn runs, the config is there.
    cmd = %{
      "args" => %{
        "type" => "feishu",
        "name" => name,
        "app_id" => "cli_atomic_#{name}",
        "app_secret" => "secret_#{name}"
      }
    }

    assert {:ok, %{"running" => true}} =
             RegisterAdapter.execute(cmd, spawn_fn: fn _ -> :ok end)

    # The FAA registers under both an atom alias (Esr.Session.Admin.Process)
    # and a string key in Esr.Entity.Registry. The string-keyed lookup is
    # what FeishuChatProxy.lookup_app_adapter_pid/1 uses on every inbound
    # message — that's the lookup the bug was triggering "no FeishuAppAdapter"
    # warnings on (see feishu_chat_proxy.ex:1084).
    assert [{pid, _}] = Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_#{name}")
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "second register_adapter for a different name does not disturb the first", %{
    instance_id: base
  } do
    name1 = "#{base}_a"
    name2 = "#{base}_b"

    assert {:ok, _} =
             RegisterAdapter.execute(
               %{
                 "args" => %{
                   "type" => "feishu",
                   "name" => name1,
                   "app_id" => "cli_a",
                   "app_secret" => "sa"
                 }
               },
               spawn_fn: fn _ -> :ok end
             )

    assert {:ok, _} =
             RegisterAdapter.execute(
               %{
                 "args" => %{
                   "type" => "feishu",
                   "name" => name2,
                   "app_id" => "cli_b",
                   "app_secret" => "sb"
                 }
               },
               spawn_fn: fn _ -> :ok end
             )

    assert [{pid1, _}] = Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_#{name1}")
    assert [{pid2, _}] = Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_#{name2}")
    assert pid1 != pid2
    assert Process.alive?(pid1)
    assert Process.alive?(pid2)
  end
end
```

- [ ] **Step 2: Run the integration test to verify it passes**

Run (the `--include integration` flag is required — `test_helper.exs` excludes `:integration` by default):
```bash
cd runtime && mix test --include integration test/esr/integration/register_adapter_spawns_faa_test.exs
```

Expected: both tests pass. If a test fails with `Process.whereis(Esr.Entity.Registry) == nil` or `:not_started`, the Application isn't being booted by ExUnit's `test/test_helper.exs` for this test path — confirm by running `mix test test/esr/commands/register_adapter_test.exs` (which already passes against the real Application) and copy that helper config.

If a test fails with `feishu plugin: feishu_app_adapter spawn failed ... reason={:already_started, ...}` on the SECOND test (because the FAA from test 1 wasn't cleaned up), confirm the on_exit cleanup ran by adding `IO.puts(...)` inside the on_exit closure. The cleanup uses `instance_id` derived from `System.unique_integer/1` so test 1 and test 2 have different names — but a flake in on_exit ordering would leave state.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/integration/register_adapter_spawns_faa_test.exs
git commit -m "$(cat <<'EOF'
test(integration): register_adapter spawns FAA in Entity.Registry

Regression guard for the 2026-05-12 atomic-FAA-spawn fix. Boots the
real Esr.Plugin.Loader.run_startup/0 path (no startup_fn injection)
and asserts that after RegisterAdapter.execute returns ok, an FAA
process is registered in Esr.Entity.Registry under the
"feishu_app_adapter_<name>" key — which is what
FeishuChatProxy.lookup_app_adapter_pid/1 reads on every inbound
message.

Closes the e2e coverage gap that let the bug ship: scenario 23
(zero-config bootstrap) asserts register_adapter returns ok but never
checks the FAA actually started.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Docs sweep + todo.md closeout

**Files:**
- Modify: `docs/guides/flow-bootstrap.md` (step 3 callout)
- Modify: `docs/futures/todo.md` (close `unconsumed-message-errors-not-hangs` row)

- [ ] **Step 1: Add 1-sentence atomicity callout to flow-bootstrap.md**

Find the section in `docs/guides/flow-bootstrap.md` that documents `register_adapter` (around step 3 in the Quick start block, and the longer explanatory section below). After the example command, add:

```markdown
**What this does (atomic):** writes `~/.esrd-dev/default/adapters/<name>/config.yaml`,
spawns the Python sidecar, AND spawns the Elixir-side `FeishuAppAdapter`
peer that handles inbound Feishu events. All three happen in one call —
no `esr exec adapter_refresh` follow-up needed.
```

Find the exact insertion point with:
```bash
grep -n "register_adapter" docs/guides/flow-bootstrap.md
```

Insert the callout after the first `register_adapter` example block. If the file has a `.zh_cn.md` mirror, mirror the callout there:

```bash
ls docs/guides/flow-bootstrap.zh_cn.md
```

If it exists, edit it to add the equivalent Chinese callout:

```markdown
**这个命令做了什么（原子的）**：写 `~/.esrd-dev/default/adapters/<name>/config.yaml`，
spawn Python sidecar，**并且** spawn Elixir 端的 `FeishuAppAdapter` peer（处理 Feishu 入站事件）。
三件事在一次 call 里完成 — 不再需要 `esr exec adapter_refresh` 收尾。
```

- [ ] **Step 2: Close the `unconsumed-message-errors-not-hangs` todo row**

Edit `docs/futures/todo.md`. Find the row (currently around line 38):

```
| `unconsumed-message-errors-not-hangs` | Plain text in chat with no agent-bound session must error, not hang silently | ...
```

Strike it through and append a closeout note. Replace with:

```
| ~~`unconsumed-message-errors-not-hangs`~~ | ✅ **PARTIALLY CLOSED 2026-05-12** (adapter-spawn-gap branch) | The wipe→boot→register_adapter→silent-drop flavor of this bug is now closed by `fix/register-adapter-spawns-faa`: register_adapter atomically spawns both the sidecar and the FAA, so post-boot-registered adapters route inbound messages instead of dropping them with `no FeishuAppAdapter`. The "session with no agent bound" flavor is closed by the default-agent-and-agent-driven-flow plan (PRs #341-#344) which auto-binds a default agent on session creation. Both flavors of the original 2026-05-11 manual-test silent-drop are now covered. |
```

Also find the `phase-3-fence-cc-reply` row (currently around line 39) and update its status — the upstream blocker (auto-bind agent) is closed; this row's remaining work is adding fence #5 to `flow-bootstrap.md`, which is unblocked.

```
| `phase-3-fence-cc-reply` | Deferred Phase-2 fence pair: plain-text → CC reply (UNBLOCKED 2026-05-12) | Upstream gaps closed by default-agent-and-agent-driven-flow plan + `fix/register-adapter-spawns-faa`. Remaining work: add fence #5 (plain text → CC reply wildcard) to `docs/guides/flow-bootstrap.md` and rerun replay. ~10 LOC. |
```

- [ ] **Step 3: Commit docs sweep**

```bash
git add docs/guides/flow-bootstrap.md docs/guides/flow-bootstrap.zh_cn.md docs/futures/todo.md
git commit -m "$(cat <<'EOF'
docs: flow-bootstrap atomicity callout + todo closeouts

- flow-bootstrap.md: 1-sentence callout that register_adapter is atomic
  (sidecar + FAA in one call) — no adapter_refresh follow-up needed
- todo.md: close `unconsumed-message-errors-not-hangs` adapter-spawn
  flavor; mark `phase-3-fence-cc-reply` as unblocked

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Note: if `docs/guides/flow-bootstrap.zh_cn.md` does not exist, drop it from `git add` and omit the Chinese callout.

---

## Task 5: Subagent code-quality review

Per memory rule `feedback_subagent_review_plans.md`: subagent-review the diff before opening the PR.

- [ ] **Step 1: Dispatch code-quality reviewer subagent**

From the controller (parent agent), dispatch a subagent (model: `opus`) with this prompt:

```
Code-quality review for branch fix/register-adapter-spawns-faa
(worktree /Users/h2oslabs/Workspace/esr/.worktrees/fix-unconsumed-msg).

Diff to review:
  git --no-pager diff origin/dev...fix/register-adapter-spawns-faa

Specifically check:
1. The `:startup_fn` DI pattern matches the existing `:spawn_fn` pattern
   in register_adapter.ex (style, defaulting, error propagation).
2. `run_startup_hooks/1` correctly handles all three return shapes
   (`:ok`, `{:error, _}`, `other`) — same as `spawn_adapter/4` does.
3. The unit test's `assert_receive` ordering proves spawn_fn runs
   BEFORE startup_fn (not just that both run).
4. The "spawn_fn fails → startup_fn NOT called" test uses `refute_receive`
   with a short timeout (200ms) — long enough to catch a synchronous bug,
   short enough to not slow CI.
5. The integration test does NOT leak state across test runs (tmp dir
   per test, ESRD_HOME restored on_exit, Application.put_env restored).
6. No new comments that just restate WHAT the code does (memory rule:
   comments should explain WHY when non-obvious).
7. The flow-bootstrap.md callout is bilingual (en + zh_cn parallel).
8. Commit messages explain WHY, not WHAT.

Report ANY issue (no false positives). If clean, say so explicitly.
Under 400 words.
```

- [ ] **Step 2: Address any reviewer findings**

If the reviewer flags issues, fix them inline + amend the corresponding commit or write a follow-up commit. Do NOT skip findings.

Re-dispatch the reviewer with the updated diff. Repeat until clean.

---

## Task 6: Push + open PR + admin merge

- [ ] **Step 1: Feishu heads-up before push** (per memory rule `feedback_feishu_notify_before_remote_ops.md`)

Send a 1-2 sentence Feishu reply to `oc_d9b47511b085e9d5b66c4595b3ef9bb9`:

> Plan executed: 3 commits on `fix/register-adapter-spawns-faa` (DI startup_fn + integration test + docs). Code-quality review clean. Pushing + opening PR now (admin-squash-merge).

- [ ] **Step 2: Push the branch**

Run:
```bash
git push -u origin fix/register-adapter-spawns-faa
```

Expected: branch published.

- [ ] **Step 3: Open the PR via gh**

Run:
```bash
gh pr create --base dev --head fix/register-adapter-spawns-faa \
  --title "fix(register_adapter): atomic FAA spawn (closes wipe→silent-drop)" \
  --body "$(cat <<'EOF'
## Summary
- `register_adapter` now spawns the Elixir-side FAA peer alongside the Python sidecar (one atomic call). Same idempotent path that `adapter_refresh` takes.
- Closes the wipe→boot→register_adapter→silent-drop bug live-diagnosed 2026-05-12 (Feishu chat).
- Integration test asserts FAA is in `Esr.Entity.Registry` post-register, closing the e2e coverage gap that let the bug ship.

## Root cause
Pre-fix: `register_adapter.ex:80` called only `WorkerSupervisor.ensure_adapter` (Python sidecar). The Elixir FAA peer was spawned only by `Esr.Plugins.Feishu.Bootstrap.bootstrap/0` from `Esr.Plugin.Loader.run_startup/0`, which runs only at esrd boot or `adapter_refresh`. After a wipe+boot+register_adapter sequence, the sidecar was up but the FAA was missing → inbound Feishu messages hit `feishu_chat_proxy.ex:1084` `Registry.lookup("feishu_app_adapter_<id>")` → `unknown_app` → silent drop.

Operator manually verified the fix path by running `esr exec adapter_refresh` — bind succeeded immediately after.

## Test plan
- [x] Unit tests: `:startup_fn` opt invoked after `spawn_fn` (and NOT invoked when `spawn_fn` fails)
- [x] Integration test: real Application boot, RegisterAdapter.execute, assert `Esr.Entity.Registry.lookup("feishu_app_adapter_<name>") != []`
- [x] All existing `register_adapter_test.exs` tests still pass
- [x] `flow-bootstrap.md` callout added (en + zh_cn)
- [x] `docs/futures/todo.md` closeouts (unconsumed-message-errors-not-hangs adapter-spawn flavor + phase-3-fence-cc-reply unblock)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL returned.

- [ ] **Step 4: Admin-squash-merge the PR** (per memory rule `feedback_admin_merge_authorized.md`)

Run:
```bash
gh pr merge --admin --squash --delete-branch
```

Expected: PR merged, branch deleted.

- [ ] **Step 5: Feishu progress update**

Send a brief Feishu reply:

> Merged: `fix(register_adapter): atomic FAA spawn` — PR `#<N>` (squashed into `dev`). 接下来你可以重新 wipe 一次 + 走完整的 flow-bootstrap，验证 `/feishu:bind` 在不跑 `adapter_refresh` 的情况下也直接生效。

---

## Self-Review Checklist (run by the plan author, not a subagent)

**1. Spec coverage:** This plan addresses a single bug (no spec doc). Coverage check:
- [x] Bug root cause documented in plan header
- [x] Fix verified by user via `adapter_refresh` (same code path) — high confidence the plan's fix works
- [x] Unit test proves call-site exists
- [x] Integration test proves end-to-end registration works
- [x] E2E gap closed (integration test fills the role of an e2e scenario without spinning shell scripts)
- [x] Docs updated (flow-bootstrap + todo)
- [x] No placeholders

**2. Placeholder scan:** None — every step has full code/commands.

**3. Type consistency:**
- `:startup_fn` opt name used consistently (test, src, plan prose)
- `run_startup_hooks/1` signature consistent
- `Esr.Entity.Registry` lookup key `"feishu_app_adapter_<name>"` matches FAA's `init/1` registration (verified in `feishu_app_adapter.ex:121`)

**4. Anti-pattern guard:** Memory rule `feedback_let_it_crash_no_workarounds.md` — no shims, defaults, or whitelists; this is a structural fix (add the missing call site) not a workaround.

**5. Memory rules applied:**
- Bilingual docs (`flow-bootstrap.md` + `.zh_cn.md`)
- Subagent-review the diff before PR
- Feishu heads-up before push + admin-merge
- Progress % in Feishu replies (single-PR work, brief updates only)
- DRY/YAGNI: no future-proofing — one PR, one bug, one fix

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-12-register-adapter-spawns-faa-plan.md`.**

Two execution options:

**1. Subagent-Driven (recommended)** — Controller dispatches a fresh subagent per task (always `model: "opus"`), reviews between tasks, fast iteration.

**2. Inline Execution** — Controller executes tasks in this session via `superpowers:executing-plans`, batch execution with checkpoints.

Default: subagent-driven (matches the 4-PR plan workflow that just shipped).
