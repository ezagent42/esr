# YAML Layout v2 — Implementation Plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to drive this task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal**: Migrate `$ESRD_HOME/<inst>/` from monolithic `adapters.yaml` + `plugins.yaml :config` to per-thing directories (`adapters/<instance>/config.yaml`, `plugins/<name>/config.yaml`). Subsumes the standalone `app_secret` fallback cleanup.

**Spec**: [`docs/superpowers/specs/2026-05-09-yaml-layout-v2-per-thing-directories.md`](../specs/2026-05-09-yaml-layout-v2-per-thing-directories.md)

**Working directory**: a fresh worktree based on `origin/dev` after spec PR #310 lands. Branch: `feat/yaml-layout-v2`.

**PR target**: GitHub PR against `dev`. Single PR, no staging. Squash-merge after green.

---

## Scope Check

**In-scope (from spec)**:
- New `Esr.Adapters` library module + `Esr.Paths` helpers (§ 4.3, 4.4)
- `Esr.Plugin.Config` 3-layer reader rewritten to per-directory layout (§ 4.1)
- `Esr.Plugin.PluginsYaml` slimmed to enabled-only (§ 4.2)
- 4 new command modules in DSL form (§ 4.6) — slash + CLI both
- Cleanup A subsumption (§ 4.7) — delete `application.ex:438-486` `ensure_app_secret` fallback, replace with fail-loud skip-spawn
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

**New code**:
- `runtime/lib/esr/adapters.ex` — library module (~120 LOC)
- `runtime/lib/esr/commands/adapter/disable.ex` — DSL command (~40 LOC)
- `runtime/lib/esr/commands/adapter/enable.ex` — DSL command (~40 LOC)
- `runtime/lib/esr/commands/adapter/remove.ex` — DSL command (~40 LOC)
- `runtime/lib/esr/commands/adapter/list.ex` — DSL command (~50 LOC)
- `runtime/test/esr/adapters_test.exs` — round-trip + reserved-name tests
- `runtime/test/esr/commands/adapter/{disable,enable,remove,list}_test.exs` — per-command DSL tests
- `tests/e2e/scenarios/<NN>_yaml_layout_v2.sh` — round-trip e2e

**Edited code**:
- `runtime/lib/esr/paths.ex` — add `plugin_*_dir/N`, `adapters_dir/0`, `adapter_dir/1`, `adapter_disabled_dir/0`; **delete** `adapters_yaml/0`
- `runtime/lib/esr/plugin/config.ex` — rewrite 3-layer reader/writer; raise on malformed yaml
- `runtime/lib/esr/plugin/plugins_yaml.ex` — strip `:config` handling, keep enabled-list ops only; raise on `:config` key presence
- `runtime/lib/esr/application.ex` — call `Esr.Adapters.list/0` (replaces lines 405-436); **delete** lines 438-486 (`ensure_app_secret` feishu fallback)
- `runtime/lib/esr/commands/register_adapter.ex` — replace `append_instance_to_yaml/4` body with `Esr.Adapters.add/3` call (DSL block stays, including `slash :none`)
- `runtime/lib/esr/plugins/feishu/bootstrap.ex` — replace yaml read with `Esr.Adapters.list/1` (lines 48-52)
- `runtime/test/esr/application_restore_adapters_test.exs` — replace fallback test with fail-loud skip-spawn assertion
- `runtime/priv/slash-routes.default.yaml` — **regenerated** (do not hand-edit)
- `README.md`, `docs/dev-guide.md` — esrd home layout updates

---

## Stage 1 — New surface, no breakage (additive)

- [ ] Add `runtime/lib/esr/paths.ex` helpers per spec § 4.4. Keep `adapters_yaml/0` for now (deletion in Stage 2).
- [ ] Add `runtime/lib/esr/adapters.ex` per spec § 4.3 (all 9 functions). `list/0` skips any directory under `adapters/` whose name starts with `_`.
- [ ] Verify: `mix compile` clean (no consumer changes yet, so no warnings).
- [ ] Verify: `mix test test/esr/adapters_test.exs` passes (unit tests added in this stage).

**Done when**: new modules exist + compile + tested in isolation; no consumer touches them yet.

## Stage 2 — Switch consumers + Cleanup A

- [ ] `runtime/lib/esr/application.ex:405-436` (`restore_adapters_from_disk/2`) — rewrite to iterate `Esr.Adapters.list/0`. The for-loop body becomes the same `spawn_fn.(name, type, config)` call; `ensure_app_secret/2` is gone.
- [ ] `runtime/lib/esr/application.ex:438-486` — **delete** entire `defp ensure_app_secret("feishu", config)` clause + comment block. Keep generic `ensure_app_secret(_type, config), do: config` IF still referenced elsewhere; otherwise delete entirely.
- [ ] `runtime/lib/esr/application.ex` call site (was line 424) — for `type == "feishu" && Map.get(config, "app_secret") in [nil, ""]`, emit `Logger.error("application: feishu adapter '#{name}' missing app_secret in adapters/<name>/config.yaml — skipping spawn. Re-run `esr exec register_adapter --type=feishu --name=#{name} --app_id=… --app_secret=…` to fix.")` and `:skipped`; do not call `spawn_fn`. Other rows unaffected.
- [ ] `runtime/lib/esr/commands/register_adapter.ex:95-113` (`append_instance_to_yaml/4`) — replace with `Esr.Adapters.add(name, "feishu", %{"app_id" => app_id, "app_secret" => secret})`. DSL block (`command :register_adapter do …`) stays untouched, **including `slash :none`** (credential-bearing args, see spec § 4.6 Slash discipline).
- [ ] `runtime/lib/esr/plugins/feishu/bootstrap.ex:48-65` — replace `YamlElixir.read_from_file(adapters_yaml_path) → instances` walk with `Esr.Adapters.list/1` (accepts `:home` opt for tests).
- [ ] `runtime/lib/esr/plugin/config.ex` — rewrite the 3-layer reader to walk per-directory paths via new `Esr.Paths.plugin_{global,user,workspace}_dir/N` helpers. Apply merge order workspace > user > global (last-wins). **Malformed yaml at any layer raises** (not silent fall-through).
- [ ] `runtime/lib/esr/plugin/plugins_yaml.ex` — strip all `:config` handling. Reading a yaml that contains `:config` or any non-`enabled` top-level key **raises** at read time.
- [ ] **Delete** `runtime/lib/esr/paths.ex` `def adapters_yaml`. Compile failures across the tree are the migration checklist; fix any remaining call sites (should be none after this stage).
- [ ] `runtime/test/esr/application_restore_adapters_test.exs` — rewrite per spec § 4.7: assert `Logger.error` matches `~r/missing app_secret in adapters\/.*\/config\.yaml/`; assert `spawn_fn` not called for that row; assert other valid rows still spawn.
- [ ] Verify: `mix compile` clean.
- [ ] Verify: `mix test test/esr/application_restore_adapters_test.exs test/esr/plugins/feishu/ test/esr/commands/register_adapter_test.exs test/esr/plugin/` all pass.

**Done when**: zero callers of old API remain; `Esr.Paths.adapters_yaml/0` is gone; full `mix test` passes (modulo pre-existing flakes in `docs/operations/known-flakes.md`).

## Stage 3 — New command modules + slash regen

- [ ] Create `Esr.Commands.Adapter.{Disable,Enable,Remove,List}` modules. Each:
  - `use Esr.Commands.Meta`
  - `command :adapter_<verb> do … end` block declaring `slash "/adapter:<verb>"`, `category "Adapters"`, `description`, `permission "adapter.<verb>"`, `arg :name, required: true` (List has no args), `error :not_found, "adapter %{name} not found"`, `error :already_disabled, "..."`, etc. as needed.
  - `def execute/1` body wraps `Esr.Adapters.<fn>/N`, returns `Render.error(__MODULE__.command_meta(), :code, %{detail: …})` on failure.
  - **All 4 expose both slash + CLI** (no `slash :none`); these commands carry no secrets. Per spec § 4.6 Slash discipline: `slash :none` is reserved for credential-bearing args.
- [ ] Per-command unit test under `runtime/test/esr/commands/adapter/`. Test happy path + each declared error code.
- [ ] Run the grammar generator (the mix task introduced by PR #304 — verify exact name with `mix help | grep esr`). It should regenerate `runtime/priv/slash-routes.default.yaml` to include `/adapter:disable`, `/adapter:enable`, `/adapter:remove`, `/adapter:list`.
- [ ] Verify: `mix esr.check_command_docs` passes (CI gate).

**Done when**: 4 new commands exist, per-command tests green, slash-routes.yaml regenerated and CI gate passes.

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
- **`Esr.Yaml.Writer` lock semantics under concurrent `disable`/`enable`.** Two operators racing `mv` on the same `adapters/<name>` directory could leave it in an inconsistent state. Likely tolerable (esrd is single-tenant per env) but flag in PR description.
- **CI grammar gate failure during Stage 3.** The regenerated yaml must be byte-identical to what `command_meta/0` produces. If hand-editing slips in, gate fails. Mitigation: run `mix esr.check_command_docs` after every commit during Stage 3.
- **Stale `adapters.yaml` on operator machines silently ignored.** Per spec design (no boot gate), an operator who forgets to wipe `~/.esrd*/default/adapters.yaml` will see esrd boot successfully but with zero adapters spawned. Mitigation: PR description includes a one-line operator wipe command; `./esr.sh adapter list` will return empty so the issue is observable.

## Out-of-scope reminders (do NOT pull in)

- Do NOT add `plugins/<name>/state/` or `plugins/<name>/cache/` conventions — separate spec.
- Do NOT add schema validation on `Esr.Plugin.Config.get/3` reads.
- Do NOT add a migration script.
- Do NOT add a boot-time legacy-layout detection / refuse-to-boot gate.
- Do NOT add backward-compat shims for `Esr.Paths.adapters_yaml/0`. Hard cutover.
- Do NOT amend the unified-command-grammar spec to codify the slash discipline. That's a separate PR.
