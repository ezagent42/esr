# YAML Layout v2 — Implementation Plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to drive this task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal**: Migrate `$ESRD_HOME/<inst>/` from monolithic `adapters.yaml` + `plugins.yaml :config` to per-thing directories (`adapters/<instance>/config.yaml`, `plugins/<name>/config.yaml`). Subsumes the standalone `app_secret` fallback cleanup.

**Spec**: [`docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md`](../specs/2026-05-09-yaml-layout-v2-per-thing-directories.md)

**Working directory**: a fresh worktree based on `origin/dev` after spec PR #310 lands. Branch: `feat/yaml-layout-v2`.

**PR target**: GitHub PR against `dev`. Single PR, no staging. Squash-merge after green.

---

## Scope Check

**In-scope (from spec, expanded after review pass #1)**:
- New `Esr.Adapters` library module + `Esr.Paths` helpers (§ 4.3, 4.4) — 10 functions including the rev-3 `rename/2` addition
- `Esr.Plugin.Config` internal change to per-directory paths (§ 4.1) — **public API names unchanged** (store_layer/4, delete_layer/3, resolve/2, get/3 all stay)
- `Esr.Plugin.PluginsYaml` already enabled-only in dev — only adding "raise on `:config`" (§ 4.2)
- 2 NEW command modules: `Esr.Commands.Adapter.{Disable,Enable}` (§ 4.6) — slash + CLI both
- 3 REFACTOR / MOVE existing command modules per § 4.6:
  - `Esr.Commands.Adapter.Remove` (refactor existing `remove.ex` body)
  - `Esr.Commands.Adapter.Rename` (refactor existing `rename.ex` body)
  - `Esr.Commands.Adapter.List` — **move** `commands/adapters/list.ex` → `commands/adapter/list.ex` + refactor body (singular namespace cleanup)
- 4 plugin-config command callers switched from `global_plugins_yaml/0` to `plugin_global_dir/1`: `commands/plugin/{show_config,set,unset,list_config}.ex`
- Cleanup A subsumption (§ 4.7) — delete `application.ex:438-486` `ensure_app_secret` fallback, replace with fail-loud skip-spawn
- Possibly small `Esr.Yaml.Writer.write_atomic/2` helper extraction (§ 4.3 atomicity correction)
- Tests + operator docs (§ 5, § 6.9)

**Out-of-scope (deferred per spec § 7)**:
- Plugin local state conventions (`plugins/<name>/state/`)
- Schema validation on read
- `_disabled/` GC policy
- Cross-platform FSEvents quirks beyond what `Esr.Yaml.Writer` already handles
- Boot-time legacy detection / refuse-to-boot gate (explicitly dropped — pre-launch, hard cutover, no defensive code for non-existent users)
- Slash-discipline amendment to unified-command-grammar spec (separate PR)

---

## File Structure

**New code** (truly new files):
- `runtime/lib/esr/adapters.ex` — library module (~140 LOC after `rename/2` addition)
- `runtime/lib/esr/commands/adapter/disable.ex` — DSL command (~40 LOC)
- `runtime/lib/esr/commands/adapter/enable.ex` — DSL command (~40 LOC)
- `runtime/test/esr/adapters_test.exs` — round-trip + reserved-name tests
- `runtime/test/esr/commands/adapter/{disable,enable}_test.exs` — per-command DSL tests
- `tests/e2e/scenarios/<NN>_yaml_layout_v2.sh` — round-trip e2e

**Refactored / moved files**:
- `runtime/lib/esr/commands/adapter/remove.ex` — rewrite body to call `Esr.Adapters.remove/1` (DSL block stays; drops inline `read_adapters_yaml` + `Esr.Yaml.Writer.write` at lines 41/54/70)
- `runtime/lib/esr/commands/adapter/rename.ex` — rewrite body to call `Esr.Adapters.rename/2` (DSL block stays; drops inline read/write at lines 66/91/110)
- `runtime/lib/esr/commands/adapters/list.ex` → **moved** to `runtime/lib/esr/commands/adapter/list.ex` (singular namespace) — rewrite body to call `Esr.Adapters.list/0` + `list_disabled/0`
- `runtime/test/esr/commands/adapter/{remove,rename,list}_test.exs` — adjust per refactor

**Edited code**:
- `runtime/lib/esr/paths.ex` — add `plugin_*_dir/N`, `adapters_dir/0`, `adapter_dir/1`, `adapter_disabled_dir/0`; **delete** `adapters_yaml/0`
- `runtime/lib/esr/plugin/config.ex` — internal path resolution change (per-directory); raise on malformed yaml; **public API unchanged** (store_layer, delete_layer, resolve, get all keep current names)
- `runtime/lib/esr/plugin/plugins_yaml.ex` — already enabled-only; only addition: raise on `:config` or non-`enabled` top-level key
- `runtime/lib/esr/application.ex` — call `Esr.Adapters.list/0` (replaces lines 405-436); **delete** lines 438-486 (`ensure_app_secret` feishu fallback)
- `runtime/lib/esr/commands/register_adapter.ex` — replace `append_instance_to_yaml/4` body with `Esr.Adapters.add/3` call (DSL block stays, including `slash :none`)
- `runtime/lib/esr/plugins/feishu/bootstrap.ex` — replace yaml read with `Esr.Adapters.list/1` (lines 48,52)
- `runtime/lib/esr/commands/plugin/show_config.ex:54` — switch `global_plugins_yaml/0` → `plugin_global_dir/1`
- `runtime/lib/esr/commands/plugin/set.ex:113` — same
- `runtime/lib/esr/commands/plugin/unset.ex:86` — same
- `runtime/lib/esr/commands/plugin/list_config.ex:27` — same
- `runtime/test/esr/application_restore_adapters_test.exs` — replace fallback test with fail-loud skip-spawn assertion
- `runtime/test/esr/plugin/config_test.exs` — adjust internal-path expectations (API surface unchanged so test bodies stay; only fixture paths shift)
- `runtime/priv/slash-routes.default.yaml` — **regenerated** via `mix esr.gen_slash_routes` (do not hand-edit)
- (optional) `runtime/lib/esr/yaml/writer.ex` — extract `write_atomic/2` helper (small addition; reused by `Esr.Adapters.add/3`)
- `README.md`, `docs/dev-guide.md` — esrd home layout updates

**Deleted**:
- `runtime/lib/esr/commands/adapters/` directory (after `list.ex` moves to singular path; directory empty)

---

## Stage 1 — New surface, no breakage (additive)

- [ ] Add `runtime/lib/esr/paths.ex` helpers per spec § 4.4. Keep `adapters_yaml/0` for now (deletion in Stage 2).
- [ ] Add `runtime/lib/esr/adapters.ex` per spec § 4.3 — **10 functions**: `list/1`, `list_disabled/1`, `get/2`, `exists?/2`, `disabled?/2`, `add/4`, `remove/2`, `disable/2`, `enable/2`, `rename/3`. `list/1` skips any directory under `adapters/` whose name starts with `_`. Each function accepts `opts` with `:home` for test override.
- [ ] (Optional) Extract `Esr.Yaml.Writer.write_atomic/2` from the tmp+rename pattern in `Esr.Plugin.PluginsYaml`. Have `Esr.Adapters.add/4` call it. (If skipping the extraction, do tmp+rename inline in `Adapters.add/4`.)
- [ ] Verify: `mix compile` clean (no consumer changes yet, so no warnings).
- [ ] Verify: `mix test test/esr/adapters_test.exs` passes (unit tests added in this stage).

**Done when**: new modules exist + compile + tested in isolation; no consumer touches them yet.

## Stage 2 — Switch consumers + Cleanup A

**Adapter storage callers** (Esr.Paths.adapters_yaml deletion blast radius — all 6):

- [ ] `runtime/lib/esr/application.ex:405-436` (`restore_adapters_from_disk/2`) — rewrite to iterate `Esr.Adapters.list/0`. The for-loop body keeps the same `spawn_fn.(name, type, config)` call; `ensure_app_secret/2` is gone.
- [ ] `runtime/lib/esr/application.ex:438-486` — **delete** entire `defp ensure_app_secret("feishu", config)` clause + comment block. Keep generic `ensure_app_secret(_type, config), do: config` IF still referenced; otherwise delete entirely.
- [ ] `runtime/lib/esr/application.ex` in-loop call site — for `type == "feishu" && Map.get(config, "app_secret") in [nil, ""]`, emit `Logger.error("application: feishu adapter '#{name}' missing app_secret in adapters/<name>/config.yaml — skipping spawn. Re-run `esr exec register_adapter --type=feishu --name=#{name} --app_id=… --app_secret=…` to fix.")` and `:skipped`; do not call `spawn_fn`. Other rows unaffected.
- [ ] `runtime/lib/esr/commands/register_adapter.ex:76-113` (`append_instance_to_yaml/4` + its call site at line 78) — replace with `Esr.Adapters.add(name, "feishu", %{"app_id" => app_id, "app_secret" => secret})`. DSL block (`command :register_adapter do …`) stays untouched, **including `slash :none`** (credential-bearing args, see spec § 4.6 Slash discipline).
- [ ] `runtime/lib/esr/commands/adapter/remove.ex:41-54,70` — replace inline `read_adapters_yaml/2` + `Esr.Yaml.Writer.write/2` body with `Esr.Adapters.remove/1`. DSL block stays.
- [ ] `runtime/lib/esr/commands/adapter/rename.ex:66-91,110` — replace inline read/write body with `Esr.Adapters.rename/2`. DSL block stays.
- [ ] **Move** `runtime/lib/esr/commands/adapters/list.ex` → `runtime/lib/esr/commands/adapter/list.ex` (singular namespace per spec § 4.6). Replace body with `Esr.Adapters.list/0` + `list_disabled/0`. After move, delete the now-empty `runtime/lib/esr/commands/adapters/` directory.
- [ ] `runtime/lib/esr/plugins/feishu/bootstrap.ex:48,52` — replace `YamlElixir.read_from_file(adapters_yaml_path) → instances` walk with `Esr.Adapters.list/1` (accepts `:home` opt for tests).

**Plugin-config storage callers** (per-directory layout):

- [ ] `runtime/lib/esr/plugin/config.ex` — internal path resolution change. Each layer reads from `<layer>/plugins/<name>/config.yaml` instead of `<layer>/plugins.yaml :config[name]`. **Public API names unchanged** (store_layer/4, delete_layer/3, resolve/2, get/3 all stay). Apply merge order workspace > user > global (last-wins). **Malformed yaml at any layer raises** (not silent fall-through).
- [ ] `runtime/lib/esr/plugin/plugins_yaml.ex` — already enabled-only in dev. Only addition: raise when reading a `plugins.yaml` that contains `:config` or any non-`enabled` top-level key.
- [ ] `runtime/lib/esr/commands/plugin/show_config.ex:54` — switch `Esr.Paths.global_plugins_yaml/0` → `Esr.Paths.plugin_global_dir/1`.
- [ ] `runtime/lib/esr/commands/plugin/set.ex:113` — same path swap (calls `store_layer/4` — call signature unchanged).
- [ ] `runtime/lib/esr/commands/plugin/unset.ex:86` — same path swap (calls `delete_layer/3` — call signature unchanged).
- [ ] `runtime/lib/esr/commands/plugin/list_config.ex:27` — same path swap.
- [ ] `runtime/lib/esr/plugin/config_snapshot.ex:86` and `runtime/lib/esr/plugin/loader.ex:192` — both call `Esr.Plugin.Config.resolve/2`. **No change required** (API name + behavior identical, only internal path resolution differs).

**API deletion**:

- [ ] **Delete** `runtime/lib/esr/paths.ex` `def adapters_yaml`. Compile failures across the tree are the migration checklist; the 6 adapter-storage callers above must all be migrated first or the build breaks.

**Tests**:

- [ ] `runtime/test/esr/application_restore_adapters_test.exs` — rewrite per spec § 4.7: assert `Logger.error` matches `~r/missing app_secret in adapters\/.*\/config\.yaml/`; assert `spawn_fn` not called for that row; assert other valid rows still spawn.
- [ ] `runtime/test/esr/plugin/config_test.exs:180,217` — these test bodies should pass unchanged because public API didn't change. Only the test fixture paths (where the test writes legacy `plugins.yaml :config`) need to shift to the new per-directory layout.
- [ ] `runtime/test/esr/commands/adapter/{remove,rename}_test.exs` — verify still pass after the body refactor (DSL block / public behavior unchanged).
- [ ] Add `runtime/test/esr/commands/adapter/list_test.exs` (replacing the moved `adapters/list_test.exs` if present).

**Verify**:

- [ ] `(cd runtime && mix compile)` — clean.
- [ ] `(cd runtime && mix test test/esr/application_restore_adapters_test.exs test/esr/plugins/feishu/ test/esr/commands/{register_adapter,adapter,plugin}_test.exs test/esr/plugin/)` — all pass.

**Done when**: zero callers of old API remain; `Esr.Paths.adapters_yaml/0` is gone; `commands/adapters/` directory is gone; full `mix test` passes (modulo pre-existing flakes in `docs/operations/known-flakes.md`).

## Stage 3 — New command modules + slash regen

**NEW modules** (truly new files):
- [ ] Create `Esr.Commands.Adapter.Disable` at `runtime/lib/esr/commands/adapter/disable.ex`:
  - `use Esr.Commands.Meta`
  - `command :adapter_disable do … end` block declaring `slash "/adapter:disable"`, `category "Adapters"`, `description`, `permission "adapter.disable"`, `arg :name, required: true`, `error :not_found, "adapter %{name} not found"`, `error :already_disabled, "adapter %{name} already disabled"`.
  - `def execute/1` body wraps `Esr.Adapters.disable/1`, returns `Render.error(__MODULE__.command_meta(), :code, %{detail: …})` on failure.
- [ ] Create `Esr.Commands.Adapter.Enable` at `runtime/lib/esr/commands/adapter/enable.ex` — symmetric to Disable.
- [ ] Both NEW commands expose both **slash + CLI** (no `slash :none`); these carry no secrets.

**REFACTOR existing modules** (already done in Stage 2 — bodies replaced; this stage just ensures DSL declarations are still consistent):
- [ ] Verify `Esr.Commands.Adapter.Remove` (refactored in Stage 2) still has its `command :adapter_remove do … end` DSL block intact + its `slash` declaration unchanged.
- [ ] Verify `Esr.Commands.Adapter.Rename` (refactored in Stage 2) still has its DSL block intact.
- [ ] Verify the moved `Esr.Commands.Adapter.List` (formerly at `commands/adapters/list.ex`) has its DSL declaration `slash "/adapter:list"` (singular) — adjust if the old file declared a plural variant.

**Tests**:
- [ ] Per-command unit test under `runtime/test/esr/commands/adapter/` for `disable_test.exs` + `enable_test.exs` (new). Test happy path + each declared error code.

**Slash routes regen**:
- [ ] Run `mix esr.gen_slash_routes` (the regenerator introduced by PR #304). It updates `runtime/priv/slash-routes.default.yaml` to include `/adapter:disable`, `/adapter:enable`. The slashes for `/adapter:remove`, `/adapter:rename`, `/adapter:list` should already be present.
- [ ] Verify: `mix esr.check_command_docs` passes (CI gate). If diff appears, commit the regenerated yaml in the same commit as the module changes.

**Done when**: 2 new commands exist + 3 existing commands refactored consistently; per-command tests green; slash-routes.yaml regenerated; CI gate passes.

## Stage 4 — E2E + operator docs

- [ ] Add `tests/e2e/scenarios/<NN>_yaml_layout_v2.sh` per spec § 5.2. Update both the `README.md` "E2E test scenarios" table AND `docs/architecture.md` "E2E coverage map" table per repo CLAUDE.md rule.
- [ ] Run `bash tests/e2e/scenarios/<NN>_yaml_layout_v2.sh` — exits 0.
- [ ] Update `docs/dev-guide.md` § "esrd home layout" (add if absent) with the new tree diagram.
- [ ] `grep -rn "adapters.yaml\|plugins.yaml" docs/` — sweep stale references in operator-facing docs (NOT in spec/notes archives that document history).
- [ ] If `docs/guides/writing-an-agent-topology.md` references `adapters.yaml`, update.

**Done when**: e2e green; docs reference v2 layout consistently.

## Stage 5 — Pre-merge verification

- [ ] `(cd runtime && mix compile)` — clean, no new warnings.
- [ ] `(cd runtime && mix test)` — pass count ≥ baseline (`docs/operations/known-flakes.md`); no NEW failures.
- [ ] `(cd runtime && mix esr.check_command_docs)` — passes.
- [ ] `bash tests/e2e/scenarios/<NN>_yaml_layout_v2.sh` — pass.
- [ ] Manual smoke: wipe `~/.esrd-dev/default/{adapters,plugins}` + `~/.esrd-dev/default/{adapters,plugins}.yaml`; restart esrd-dev; run `./esr.sh --env=dev adapter add type=feishu name=… app_id=… app_secret=…`; verify `~/.esrd-dev/default/adapters/<name>/config.yaml` written; restart; verify spawn happens.
- [ ] Manual smoke: `./esr.sh --env=dev adapter disable <name>` → `~/.esrd-dev/default/adapters/_disabled/<name>/config.yaml` exists, original gone; restart confirms no spawn for disabled.
- [ ] Open PR with title `feat: yaml layout v2 — per-thing directories (subsumes Cleanup A)`. Body references spec PR #310, lists subsumed work, includes test plan checklist.

**Done when**: PR opened against `dev`, CI green, ready for review.

---

## Risks

- **`Esr.Plugin.Config` rewrite touches a hot path.** Many plugins call this on every operation. Verify the per-directory read isn't measurably slower (one `File.read` vs two extra `File.exists?` checks per layer). If hot-path measurement matters, add a `:persistent_term` cache keyed on path mtime.
- **`Esr.Yaml.Writer.write/2` is NOT atomic** — review pass #1 caught the original spec claim was wrong. It's plain `File.write` (overwrite-in-place). `Esr.Adapters.add/4` either does inline tmp+rename or extracts a new `write_atomic/2` helper. Recommend the extraction (canonical home + future re-use). Disable/enable use `mv` which is OS-atomic on same filesystem; remove is `rm -rf` (atomicity not relevant). Inconsistency note: `register_adapter.ex` currently calls plain `Yaml.Writer.write/2` and is not atomic — Stage 2's switch to `Esr.Adapters.add/4` fixes this incidentally.
- **Concurrent `disable`/`enable` race.** Two operators racing `mv` on the same `adapters/<name>` directory could leave it in inconsistent state. Tolerable (esrd is single-tenant per env) but flag in PR description.
- **CI grammar gate failure during Stage 3.** The regenerated yaml must be byte-identical to what `command_meta/0` produces. If hand-editing slips in, gate fails. Mitigation: run `mix esr.check_command_docs` after every commit during Stage 3.
- **Stale `adapters.yaml` on operator machines silently ignored.** Per spec design (no boot gate), an operator who forgets to wipe `~/.esrd*/default/adapters.yaml` will see esrd boot successfully but with zero adapters spawned. Mitigation: PR description includes a one-line operator wipe command; `./esr.sh adapter list` will return empty so the issue is observable.
- **Existing rename.ex on dev has its own atomicity story** (it does read-modify-write of the monolithic `adapters.yaml` — non-atomic by definition). After refactor it inherits whatever atomicity `Esr.Adapters.rename/2` provides (POSIX `rename(2)` on same fs = atomic). Net win.

## Out-of-scope reminders (do NOT pull in)

- Do NOT add `plugins/<name>/state/` or `plugins/<name>/cache/` conventions — separate spec.
- Do NOT add schema validation on `Esr.Plugin.Config.get/3` reads.
- Do NOT add a migration script.
- Do NOT add a boot-time legacy-layout detection / refuse-to-boot gate.
- Do NOT add backward-compat shims for `Esr.Paths.adapters_yaml/0`. Hard cutover.
- Do NOT amend the unified-command-grammar spec to codify the slash discipline. That's a separate PR.
