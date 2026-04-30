# Yaml authoring lessons

**Living document**. Started 2026-04-30 during PR-21κ (slash-routes yaml). Each new yaml subsystem appends its lessons here so future ones can reuse.

The idea: ESR has 6+ yaml files now (`workspaces.yaml`, `users.yaml`, `capabilities.yaml`, `agents.yaml`, `adapters.yaml`, `slash-routes.yaml`). Every new yaml subsystem repeats some of the same patterns (load + validate + ETS snapshot + Watcher + first-boot bootstrap). Patterns that worked + traps that bit go here.

---

## Patterns that work

### Pattern: 4-piece subsystem

Every yaml-driven subsystem in ESR has the same 4-piece shape. Copy this when adding a new one:

1. **`Esr.<Name>` (GenServer + ETS)** — public read API (`get/1`, `lookup/1`, `list/0`); `load_snapshot/1` for atomic ETS replace; the GenServer is just the snapshot owner, reads bypass it via direct ETS ops.
2. **`Esr.<Name>.FileLoader` (pure module)** — `load(path) -> :ok | {:error, reason}` reads + validates yaml + calls `Esr.<Name>.load_snapshot/1`.
3. **`Esr.<Name>.Watcher` (GenServer with FileSystem.Watcher)** — `init/1` does initial `FileLoader.load/1` + subscribes to `FileSystem`; `handle_info({:file_event, _, {path, _}})` matches by basename and reloads.
4. **`Esr.Paths.<name>_yaml/0` helper** — single source of truth for path resolution (`ESRD_HOME`/`ESR_INSTANCE` keyed).

References:
- `Esr.Workspaces.Registry` + `Esr.Workspaces.Watcher` — canonical example
- `Esr.Capabilities.{Grants, FileLoader, Watcher}` — same shape
- `Esr.Users.{Registry, FileLoader, Watcher}` — PR-21a copy

### Pattern: atomic ETS snapshot swap

```elixir
def handle_call({:load, snapshot}, _from, state) do
  :ets.delete_all_objects(@table)
  Enum.each(snapshot, fn {k, v} -> :ets.insert(@table, {k, v}) end)
  {:reply, :ok, state}
end
```

`delete_all_objects` + insert loop is atomic enough — readers see EITHER the old snapshot OR the new one (no torn state) because they're called via `handle_call` (serial). Reads via `:ets.lookup/2` go directly without the GenServer hop.

### Pattern: failure-keeps-previous-snapshot

```elixir
case validate(yaml) do
  {:ok, snapshot} ->
    Grants.load_snapshot(snapshot)
    Logger.info("loaded N entries")
    :ok
  {:error, reason} ->
    Logger.error("load failed (#{inspect(reason)}); keeping previous snapshot")
    {:error, reason}
end
```

If yaml is malformed, fail loud (log) but **keep running with the previous snapshot**. Operators get a chance to fix the typo without a brief outage.

The exception: first-boot empty snapshot. There IS no previous; the system starts empty until a valid yaml lands. Document the empty-state fallback explicitly per subsystem (`capabilities.yaml` empty → all checks deny; `slash-routes.yaml` empty → all slashes return "unknown command").

### Pattern: `Code.ensure_loaded?/1` for module-name strings in yaml

If yaml carries an Elixir module name as a string (e.g. `command_module: "Esr.Admin.Commands.Session.New"`):

**Wrong**: `Module.safe_concat([str])` — only resolves modules already in the BEAM atom table at call time. Fragile in tests with lazy loading + at first-boot validation.

**Right**:
```elixir
mod = Module.concat([str])
if Code.ensure_loaded?(mod), do: {:ok, mod}, else: {:error, {:unknown_module, str}}
```

`Code.ensure_loaded?/1` triggers code-loading if needed and returns whether the module ended up loaded. Safe on cold-boot.

### Pattern: priv/<file>.default.yaml seeding

For yamls operators may need to bootstrap on first run, ship a default in `priv/`:

```elixir
def maybe_seed_default(target_path) do
  if not File.exists?(target_path) do
    src = Application.app_dir(:esr, "priv/<file>.default.yaml")
    File.mkdir_p!(Path.dirname(target_path))
    File.cp!(src, target_path)
    Logger.info("seeded #{target_path} from priv default")
  end
end
```

`priv/` is packaged in Mix releases; `Application.app_dir(:esr, "priv/...")` resolves correctly in dev + prod.

**Caveat (PR-21κ Phase 1)**: `Esr.Capabilities.Supervisor.maybe_bootstrap_file/1` looks similar but is **not** the same pattern — it writes a synthesized string conditional on `ESR_BOOTSTRAP_PRINCIPAL_ID` env var. Pre-PR-21κ no module did `priv/`-based copy. PR-21κ's `Esr.SlashRoutes` is the canonical first example.

---

## Traps that bit

### Trap: `Module.safe_concat/1` fails at first-boot

(See pattern above.) Subagent caught this during PR-21κ spec review. The naive choice for "load this module by string" is `Module.safe_concat([str])`, but it only resolves already-atomized names. Tests with lazy code-loading + first-boot before all modules are loaded will fail flakily. Always use `Code.ensure_loaded?/1` followed by `Module.concat/1`.

### Trap: yaml-only logic for what's actually code

Boundary discussion (see `docs/superpowers/specs/2026-04-30-slash-routes-yaml-design.md` §"What stays in code"): yaml describes WHAT, code does HOW.

Things that look like config but are actually code:
- **Argument derivation** (e.g. `cwd = "<root>/.worktrees/<branch>"` from PR-21θ) — yaml could specify "derive cwd from these fields" but the syntax becomes a mini-DSL; just put the derivation in the command module's `execute/1` as ~3 LOC of Elixir.
- **Validation logic** (regex matches, business invariants) — yaml schema validators handle "this field is a string"; "this field matches `[A-Za-z0-9-]+`" works in yaml as a regex string but the validation algorithm stays in Elixir.

Rule of thumb: if the would-be yaml entry references "do this then that based on input" (sequential / conditional), it's code. yaml is flat lookup.

### Trap: hardcoded list across multiple files

Pre-PR-21κ slash routing had the slash command surface spread across 3 files:
- `feishu_app_adapter.ex` — bypass list
- `slash_handler.ex` — parsers
- `dispatcher.ex` — kind→module + kind→permission maps

Adding a slash required editing all 3. Worse: forgetting one (today's `/list-agents` has no Dispatcher mapping; today's `/new-session` is missing from FAA's bypass list) silently breaks the operator path.

**Rule**: if a "fact" lives in N>1 files in code, it should live in 1 yaml file. The 3-layer hardcoded slash surface was a flag that we should have yaml-ified earlier.

### Trap: hot-reload via FSEvents misses some editor save patterns

macOS FSEvents reports `:created`/`:modified`/`:renamed`/`:removed` events. Vim's atomic-write (write to `.swp`, rename onto target) fires `:renamed` which the watcher catches. **But editors that delete-then-create** (some IDEs, `mv` from a different filesystem) fire `:removed` then `:created`, and our watchers usually only listen on `:modified` — missing the reload.

(See `docs/notes/actor-topology-routing.md` §"Watcher not reacting".)

**Workaround**: `touch <yaml>` to force a `:modified` event after the rename+delete dance.

**Better fix not yet applied**: have the Watcher listen on `:created` too, OR poll mtime as a fallback. Defer until it actually bites in prod.

### Trap: `YamlElixir.write_to_string!/1` doesn't exist

In tests it's tempting to round-trip via yaml string:
```elixir
yaml_str = YamlElixir.write_to_string!(map)   # ← undefined function
File.write!(path, yaml_str)
FileLoader.load(path)
```

`yaml_elixir` is read-only — there's no encoder. **Two workarounds**:
- Hand-write yaml strings via heredocs (verbose but explicit)
- Bypass yaml entirely: call your `Registry.load_snapshot/1` with the validated internal shape

PR-21κ test fixtures use the second approach — `load_fixture/1` constructs the post-validation snapshot directly. The yaml-parse path is exercised separately via fixture files written via heredocs.

### Trap: yaml schema migration

`workspaces.yaml` has changed schema multiple times: PR-21c added `owner`/`root`, PR-22 removed `root`. Each schema change required a yaml migration step (manual or via `Esr.Yaml.Writer`'s round-trip).

**Rule**: include `schema_version: <int>` at the top of every yaml. Increment on breaking changes. FileLoader rejects unknown versions or migrates inline if old.

`slash-routes.yaml` starts at `schema_version: 1`.

---

## Tests checklist for a new yaml subsystem

Copy this into the new subsystem's PR plan:

- [ ] `<name>_test.exs` — load valid fixture; lookup succeeds for known key + fails for unknown
- [ ] Reject: malformed yaml (parse error)
- [ ] Reject: missing required field
- [ ] Reject: unknown field type (e.g. wrong scope prefix, unknown_module)
- [ ] Hot-reload: write fixture → call `FileLoader.load/1` → `Registry.get/1` returns new value
- [ ] Boot ordering: `Esr.<Name>` is up before any consumer (verify via supervisor child position)
- [ ] First-boot empty: no yaml file → snapshot empty → all reads return `:not_found` / `nil`
- [ ] First-boot priv seed: no yaml file at `<runtime_home>` → priv default copied → snapshot loaded

---

## When NOT to add a yaml

- **Algorithm, not lookup**: cap-matching glob logic (`Grants.matches?/2`), envelope routing rules — code.
- **High-frequency hot path**: don't add yaml to anything that runs per-message (cache yaml content in ETS once at boot; don't read yaml from disk per request).
- **Internal/operator-not-tunable**: e.g. supervisor restart strategies, GenServer timeouts that affect protocol invariants. Keep these in code; the operator shouldn't tune them blindly.

---

## Maintenance

When you add a new yaml-driven subsystem:

1. Append a "Lessons from PR-#" section here recording any new traps you hit.
2. Link it from `docs/notes/README.md`.
3. If you discover a pattern that other subsystems should adopt, write it in "Patterns that work" with example code.
4. If you remove a pattern (it stopped working), strike it through with a note about why.
