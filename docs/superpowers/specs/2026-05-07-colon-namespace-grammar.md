# Spec: Colon-Namespace Slash Grammar — Complete Switch

**Date:** 2026-05-07
**Branch:** `spec/colon-namespace-grammar`
**Status:** PENDING USER APPROVAL — DO NOT OPEN PR YET

---

## §1 — Scope and Motivation

ESR's current slash surface mixes three separator styles: dash (`/new-session`,
`/list-agents`), space (`/workspace info`, `/plugin install`), and no-separator bare
verbs (`/help`, `/attach`). This inconsistency was surfaced as Cross-cutting gap #1 in
`docs/manual-checks/2026-05-06-bootstrap-flow-audit.md`:

> "The single biggest source of grammar mismatches. ESR's slash grammar today mixes dash,
> space, and no-separator forms. A consistent `<group>:<verb>` form would simplify mental
> load and let several proposed slashes work without functional changes."

Steps 8, 9, 10, and 12 of the operator bootstrap journey all failed the Grammar dimension
of the audit because the operator's natural expectation — `/session:new`, `/workspace:add`,
`/agent:add`, `/agent:inspect` — did not match shipped forms.

This spec translates the decisions locked by the user on **2026-05-06 (Feishu)** into a
complete implementation plan. The locked decisions are referenced below and are not
re-debated.

**Out of scope:** the escript `esr` subcommand syntax (`esr workspace list`, `esr cap grant`,
etc.) is NOT changed. That surface uses space-separated subcommands routed through
`Esr.Cli.Main`'s catch-all to `parse_admin_flags/4`, which concatenates tokens into
`kind_subaction` internal kinds. The colon-namespace change applies exclusively to the
slash surface (operator messages starting with `/` dispatched through
`Esr.Entity.SlashHandler`). This was confirmed by reading
`runtime/lib/esr/cli/main.ex:186-199`, which drives escript routing entirely through
internal kind names — it never constructs slash strings.

---

## §2 — Inventory

### Locked decisions (user 2026-05-06)

1. **Complete switch — no aliases.** Old grammar is REMOVED. After ship, old-form input
   returns a structured error suggesting the new form. This is not an alias — it is a
   one-shot cutover helper.
2. **Multi-verb resources keep dash inside the verb part.** `/workspace add-folder` becomes
   `/workspace:add-folder`, not `/workspace:addFolder` or `/workspace:folder add`.
3. **No deprecation period.** One ship, hard cutover.

### Bare-verb decision (spec author, 2026-05-07)

Two bare-verb commands require a policy decision not covered by the locked decisions above:

- `/help` — meta-system; no resource group.
- `/doctor` — meta-system; no resource group.

**Decision:** Keep `/help` and `/doctor` bare (no colon). These are meta-system commands
that do not operate on a resource group. Adding a `/meta:` prefix would be artificial and
would break operator muscle memory for the one command they use to discover all other
commands. Every other command takes a colon form.

For the remaining bare verbs that ARE resource-adjacent:

| bare form | group reasoning | new form |
|---|---|---|
| `/attach` | attaches to a session | `/session:attach` |
| `/sessions` | lists sessions | `/session:list` |
| `/key` | sends keystrokes to session PTY | `/session:key` |
| `/whoami` | identity — user resource | `/user:whoami` |
| `/list-agents` | lists agents | `/agent:list` |
| `/actors` | lists live actor peers (diagnostic) | `/actor:list` |
| `/new-workspace` | workspace resource | `/workspace:new` |
| `/new-session` | session resource | `/session:new` |
| `/end-session` | session resource | `/session:end` |

### Full inventory table

30 primary slash entries + 5 alias entries = 35 total named forms to migrate.

| before | after | rule applied |
|---|---|---|
| `/help` | `/help` | bare meta — keep as-is (see §2 bare-verb decision) |
| `/doctor` | `/doctor` | bare meta — keep as-is (see §2 bare-verb decision) |
| `/whoami` | `/user:whoami` | bare verb → colon, infer group=user |
| `/key` | `/session:key` | bare verb → colon, infer group=session (PTY belongs to session) |
| `/new-workspace` | `/workspace:new` | dash → colon, group=workspace, verb=new |
| `/workspace list` | `/workspace:list` | space → colon |
| `/workspace edit` | `/workspace:edit` | space → colon |
| `/workspace add-folder` | `/workspace:add-folder` | space → colon, dash stays in verb |
| `/workspace remove-folder` | `/workspace:remove-folder` | space → colon, dash stays in verb |
| `/workspace bind-chat` | `/workspace:bind-chat` | space → colon, dash stays in verb |
| `/workspace unbind-chat` | `/workspace:unbind-chat` | space → colon, dash stays in verb |
| `/workspace remove` | `/workspace:remove` | space → colon |
| `/workspace rename` | `/workspace:rename` | space → colon |
| `/workspace use` | `/workspace:use` | space → colon |
| `/workspace import-repo` | `/workspace:import-repo` | space → colon, dash stays in verb |
| `/workspace forget-repo` | `/workspace:forget-repo` | space → colon, dash stays in verb |
| `/workspace info` | `/workspace:info` | space → colon |
| `/workspace describe` | `/workspace:describe` | space → colon |
| `/workspace sessions` | `/workspace:sessions` | space → colon (lists sessions scoped to a workspace) |
| `/sessions` | `/session:list` | bare alias → primary colon form, group=session |
| `/list-sessions` (alias of `/sessions`) | removed — covered by `/session:list` | alias removed per locked decision 1 |
| `/new-session` | `/session:new` | dash → colon, group=session, verb=new |
| `/session new` (alias of `/new-session`) | removed — covered by `/session:new` | alias removed per locked decision 1 |
| `/end-session` | `/session:end` | dash → colon, group=session, verb=end |
| `/session end` (alias of `/end-session`) | removed — covered by `/session:end` | alias removed per locked decision 1 |
| `/list-agents` | `/agent:list` | dash → colon, group=agent, verb=list |
| `/actors` | `/actor:list` | bare verb → colon, infer group=actor |
| `/list-actors` (alias of `/actors`) | removed — covered by `/actor:list` | alias removed per locked decision 1 |
| `/attach` | `/session:attach` | bare verb → colon, infer group=session |
| `/plugin list` | `/plugin:list` | space → colon |
| `/plugin info` | `/plugin:info` | space → colon |
| `/plugin install` | `/plugin:install` | space → colon |
| `/plugin enable` | `/plugin:enable` | space → colon |
| `/plugin disable` | `/plugin:disable` | space → colon |

**Slash count:** 30 primary entries in yaml (verified: `grep -c '^  "/' runtime/priv/slash-routes.default.yaml` returns 30). After migration: 30 primary entries, 0 aliases.

### Removed aliases (no replacement, covered by new primary)

| removed alias | covered by |
|---|---|
| `/list-sessions` | `/session:list` |
| `/session new` | `/session:new` |
| `/session end` | `/session:end` |
| `/list-actors` | `/actor:list` |

---

## §3 — Implementation Plan

### 3.1 `runtime/priv/slash-routes.default.yaml` (~80 key edits)

Rewrite all 30 primary slash keys to colon form. Remove all `aliases:` fields (per locked
decision 1 — complete switch, no aliases). The `schema_version` remains 1; no schema
change is required because the yaml structure is identical — only the key strings change.

Files to audit: only `runtime/priv/slash-routes.default.yaml`. No other yaml files
reference slash names.

Estimated effort: mechanical; ~80 string edits across ~500 lines.

### 3.2 `runtime/lib/esr/resource/slash_route/registry.ex`

**Analysis of matching logic:** the registry uses `keys_in_text/1` which splits on
whitespace (`~r/\s+/`), not on colons. A colon-form key like `/session:new` will be
treated as a single token, which is correct — no multi-word split is needed for colon
forms. The fallback `slash_head/1` also splits on whitespace and will extract `/session:new`
as the entire head for a text like `/session:new workspace=foo name=bar`. This is correct.

**Conclusion:** no logic change required in `registry.ex`. The ETS-backed lookup
accepts arbitrary string keys; adding `/session:new` as a key instead of `/new-session`
is handled transparently.

**Patch scope:** 0 logic LOC. Only the yaml (§3.1) changes the key strings.

**Verify:** confirm `keys_in_text/1` and `slash_head/1` do not assume a space separator
in the slash key itself. They do not — both split on `\s+`, which means a colon-form key
is treated atomically. Confirmed at `registry.ex:297-316`.

### 3.3 `runtime/lib/esr/resource/slash_route/file_loader.ex`

**Analysis:** `validate_slash_key/1` validates that the key starts with `/` and nothing
else (line 127-128). Colon-form keys like `/session:new` still start with `/`, so the
validator accepts them without any change.

**Conclusion:** no change required.

### 3.4 `runtime/lib/esr/entity/slash_handler.ex` — deprecated_slash cutover helper

**Analysis:** `strip_slash_prefix/2` strips the matched `route.slash` prefix from the
input text using `String.split(trimmed, slash, parts: 2)`. For colon forms, this works
correctly because the slash key is a single token with no spaces. The function is correct.

**New addition required:** a hardcoded `@deprecated_slashes` map that catches old-form
input and returns a structured error. This is NOT an alias — it fires only when the lookup
returns `:not_found` for a name matching a known old form, and returns one structured
error per call.

Add to `slash_handler.ex` immediately after the `:not_found` branch in `handle_cast/2`:

```elixir
@deprecated_slashes %{
  "/new-session"       => "/session:new",
  "/session new"       => "/session:new",
  "/end-session"       => "/session:end",
  "/session end"       => "/session:end",
  "/sessions"          => "/session:list",
  "/list-sessions"     => "/session:list",
  "/workspace sessions"=> "/workspace:sessions",
  "/workspace list"    => "/workspace:list",
  "/workspace edit"    => "/workspace:edit",
  "/workspace add-folder"    => "/workspace:add-folder",
  "/workspace remove-folder" => "/workspace:remove-folder",
  "/workspace bind-chat"     => "/workspace:bind-chat",
  "/workspace unbind-chat"   => "/workspace:unbind-chat",
  "/workspace remove"  => "/workspace:remove",
  "/workspace rename"  => "/workspace:rename",
  "/workspace use"     => "/workspace:use",
  "/workspace import-repo"   => "/workspace:import-repo",
  "/workspace forget-repo"   => "/workspace:forget-repo",
  "/workspace info"    => "/workspace:info",
  "/workspace describe"=> "/workspace:describe",
  "/new-workspace"     => "/workspace:new",
  "/list-agents"       => "/agent:list",
  "/actors"            => "/actor:list",
  "/list-actors"       => "/actor:list",
  "/attach"            => "/session:attach",
  "/whoami"            => "/user:whoami",
  "/key"               => "/session:key",
  "/plugin list"       => "/plugin:list",
  "/plugin info"       => "/plugin:info",
  "/plugin install"    => "/plugin:install",
  "/plugin enable"     => "/plugin:enable",
  "/plugin disable"    => "/plugin:disable"
}
```

The `:not_found` branch becomes:

```elixir
:not_found ->
  old = slash_head(text)
  case Map.get(@deprecated_slashes, old) ||
       Map.get(@deprecated_slashes, two_token_head(text)) do
    nil ->
      Esr.Slash.ReplyTarget.dispatch(target, {:text, "unknown command: #{old}"}, ref)
    new_name ->
      Esr.Slash.ReplyTarget.dispatch(
        target,
        {:error, %{
          "type"    => "deprecated_slash",
          "old"     => old,
          "new"     => new_name,
          "message" => "slash command renamed; use #{new_name}"
        }},
        ref
      )
  end
  {:noreply, state}
```

Where `two_token_head/1` extracts the first two whitespace-separated tokens (for detecting
space-separated old forms like `/workspace info`):

```elixir
defp two_token_head(text) do
  text
  |> String.trim()
  |> String.split(~r/\s+/, parts: 3, trim: true)
  |> Enum.take(2)
  |> Enum.join(" ")
end
```

**Lifetime:** the `@deprecated_slashes` map survives one release minimum. Removal is a
separate PR after operators have migrated.

**Estimated LOC:** ~45 LOC added.

### 3.5 `runtime/lib/esr/commands/help.ex`

`render/0` calls `Esr.Resource.SlashRoute.Registry.list_slashes/0` and renders
`route.slash` directly. After the yaml is updated, `route.slash` will already be
`/session:new`, `/workspace:list`, etc. No rendering logic change is needed.

However, the `category_order/1` function hard-codes category names. These will remain
unchanged (Workspace, Sessions, Agents, etc.) — category labels are not affected by the
grammar change.

The help footer references `/doctor` by name:

```elixir
"诊断细节（cap、URI、状态）请用 /doctor。"
```

`/doctor` is a kept bare-form command, so this line requires no change.

**Conclusion:** no change required to `help.ex`, assuming the yaml keys are updated.

### 3.6 `runtime/lib/esr_web/controllers/slash_schema_controller.ex`

The controller calls `Esr.Resource.SlashRoute.Registry.dump/1` which serializes the
`route.slash` field verbatim. After the yaml is updated, the JSON output will emit colon
forms automatically. No controller change required.

The schema version field stays at `1` — the shape is unchanged, only string values change.

### 3.7 `runtime/test/` — test files with slash literals

The following test files construct slash names as literal strings and must be updated:

| file | literals to update |
|---|---|
| `runtime/test/esr/entity/slash_handler_dispatch_test.exs` | `/sessions`, `/list-sessions`, `/help`, `/new-workspace`, route helpers |
| `runtime/test/esr/resource/slash_route/registry_test.exs` | `/help`, `/sessions`, `/list-sessions`, `/workspace`, `/workspace info`, `/new-session` |
| `runtime/test/esr/commands/help_test.exs` | `/help`, `/sessions`, `/new-session` |
| `runtime/test/esr/integration/new_session_smoke_test.exs` | `/new-session` |
| `runtime/test/esr/integration/feishu_slash_new_session_test.exs` | `/new-session` |
| `runtime/test/esr/plugins/feishu/feishu_app_adapter_test.exs` | `/help`, `/whoami`, `/doctor`, `/new-workspace` |

Two new unit test files must be added:

1. `runtime/test/esr/resource/slash_route/colon_form_test.exs` — verifies that all colon
   forms in the yaml load correctly and resolve via `Registry.lookup/1`.
2. `runtime/test/esr/entity/deprecated_slash_test.exs` — verifies that every key in
   `@deprecated_slashes` returns a `deprecated_slash` error with the correct `new` field.

**Estimated LOC:** ~80 LOC edits across existing tests; ~50 LOC in new tests.

### 3.8 `docs/` — documents with old slash names

The following docs quote old slash names and must be updated mechanically:

```
grep -rln '/new-session\|/list-agents\|"/workspace info\|/plugin install\|/new-workspace\|/end-session\|/list-sessions\|/list-actors\|/actors\|/attach\|/sessions\|/whoami\|/key ' docs/
```

Affected files (from grep during spec authoring):

- `docs/dev-guide.md`
- `docs/cookbook.md`
- `docs/futures/channel-client-phx-py-alignment.md`
- `docs/manual-checks/2026-05-06-bootstrap-flow-audit.md` and `.zh_cn.md`
- `docs/operations/dev-prod-isolation.md`
- `docs/notes/2026-05-06-scenarios-deletion-and-python-cli-removal.md`
- `docs/notes/2026-05-05-cli-channel-migration.md`
- `docs/notes/erlexec-worker-lifecycle.md`
- `docs/guides/writing-an-agent-topology.md`
- `docs/principles/01-e2e-faces-production.md`
- `docs/superpowers/progress/` files (historical; note-only updates)
- `docs/superpowers/plans/` files (historical; note-only updates)

The audit doc and plan docs are historical notes — update them in place with inline
correction notices rather than wholesale rewrites.

**Estimated LOC:** ~40 line edits across docs.

---

## §4 — Migration Story

### Operator upgrade

All operators upgrade in lockstep with the deploy. There is no rolling upgrade path —
per locked decision 3, there is no deprecation period. The `@deprecated_slashes` map
provides a one-release grace window where old names produce an actionable error rather
than `unknown command`.

### Adapter sidecar verification

Adapter sidecars (Feishu, future Telegram) do not construct slash names directly — they
pass through whatever the human typed. Verified by reading
`runtime/lib/esr/entity/slash_handler.ex`: the dispatch path receives the raw
`envelope["payload"]["text"]` or `envelope["payload"]["args"]["content"]` and calls
`Registry.lookup(text)` against it. Adapters are transparent.

### Plugin manifest verification

Plugin manifests (`runtime/lib/esr/plugins/*/manifest.yaml`) do not pin slash names.
Verified by grepping:

```
grep -rn 'slash\|/new-session\|/plugin\|/workspace' runtime/lib/esr/plugins/*/manifest.yaml
```

No matches. Plugin manifests declare `name`, `description`, `agents`, `required_env`,
and similar fields — none reference slash command strings.

### E2E scenario verification

E2E scenarios (`tests/e2e/scenarios/*.sh`) invoke the runtime via the admin queue using
internal kind names (`esr admin submit session_new`, `esr admin submit session_end`,
`esr admin submit plugin_list`, etc.) — NOT via slash text. This was confirmed by reading
`tests/e2e/scenarios/01_single_user_create_and_end.sh:33-43` and
`tests/e2e/scenarios/11_plugin_cli_surface.sh:51-57`.

**Conclusion:** no e2e scenario files need to be updated for the slash grammar change.
The scenarios route through internal kind names which are not affected by this spec.

However, `tests/e2e/scenarios/common.sh:23` and other files contain comments that
reference `/new-session` and `/end-session`. Update those comments for accuracy.

Affected e2e scenario files (comment-only updates):

- `tests/e2e/scenarios/common.sh`
- `tests/e2e/scenarios/01_single_user_create_and_end.sh`
- `tests/e2e/scenarios/02_two_users_concurrent.sh`

---

## §5 — Risk Register

### Risk 1: Operator scripts or docs outside this repo reference old names

**Probability:** medium. Operators may have bookmarked Feishu chat history or local
scripts that send `/new-session` etc.

**Mitigation:** the `@deprecated_slashes` map produces a structured error
`{"type": "deprecated_slash", "old": ..., "new": ..., "message": "slash command renamed;
use <new>"}` for every removed name. Operators receive an actionable error on first use.

### Risk 2: In-flight branches construct slash names as string literals

**Probability:** low-medium. Any branch that adds tests using `/new-session` or
`/workspace info` literals will conflict on merge.

**Mitigation:** land this PR after current in-flight branches (`feature/t12-channel-server-detach-notification`) are merged into `dev`. If branches must merge concurrently,
rebase them after this PR lands and update their slash literals.

### Risk 3: Feishu chat history — operators scroll back and re-execute old-form messages

**Probability:** medium. Feishu shows message history; old `/new-session` messages remain
visible.

**Mitigation:** same as Risk 1 — the `@deprecated_slashes` cutover helper fires on
old-form input.

### Risk 4: Registry lookup multi-word prefix candidate generation with colon-form keys

**Probability:** none, by design. The `keys_in_text/1` function in `registry.ex:307-315`
generates candidates by splitting on whitespace and joining subsets. For `/session:new`,
there is only one whitespace-separated token, so the candidate list is `["/session:new"]`.
The ETS lookup finds it directly. The whitespace-split prefix logic is irrelevant for
colon forms and harmless.

---

## §6 — Test Plan

### Unit tests (new)

**File:** `runtime/test/esr/resource/slash_route/colon_form_test.exs`

Covers:

- Each colon-form slash key resolves via `Registry.lookup/1` to the expected kind.
  Spot-check: `/session:new`, `/workspace:add-folder`, `/plugin:enable`, `/agent:list`,
  `/actor:list`, `/user:whoami`, `/session:attach`, `/session:key`.
- `/help` and `/doctor` still resolve (bare forms kept).
- Old-form keys (`/new-session`, `/workspace info`) return `:not_found` after migration.

**File:** `runtime/test/esr/entity/deprecated_slash_test.exs`

Covers:

- For every key in `@deprecated_slashes`, dispatching the old form returns a reply with
  `type == "deprecated_slash"` and `new == <expected new form>`.
- The full old-form input (including trailing args) is handled: `/new-session esr-dev name=x`
  extracts `/new-session` as the head and returns the right error.
- Old two-token forms (`/workspace info`, `/plugin list`) produce the correct error.

### Unit tests (updated)

- `registry_test.exs` — update all fixture slash keys from old to colon form; verify
  multi-word match still works for `/workspace:add-folder` (single token; no multi-word
  needed, but test should confirm no regression).
- `slash_handler_dispatch_test.exs` — update all route/envelope helpers to colon form.
- `help_test.exs` — update route fixtures to colon form; assert rendered output shows
  colon names.
- `new_session_smoke_test.exs` and `feishu_slash_new_session_test.exs` — replace all
  `/new-session` literals with `/session:new`.
- `feishu_app_adapter_test.exs` — replace `/new-workspace`, `/whoami`, `/doctor` literals
  (note: `/help` and `/doctor` are kept bare; only `/whoami` changes to `/user:whoami`).

### E2E tests (representative scenarios)

The grammar change does not affect e2e scenarios (they use internal kinds). However, two
representative scenarios should continue to pass after all code changes are landed:

1. `tests/e2e/scenarios/01_single_user_create_and_end.sh` — session lifecycle via admin
   queue (kind-based, unaffected by slash rename).
2. `tests/e2e/scenarios/08_plugin_core_only.sh` — plugin admin surface; the scenario uses
   kind-based submission, not slash text, so it verifies the command modules remain
   functional after renaming.

---

## §7 — Summary of Decisions Made by Spec Author

The following micro-decisions were made during spec authoring and are NOT in the
user-locked set. Flag these for user confirmation:

1. **`/help` and `/doctor` stay bare.** Alternative: `/meta:help`, `/meta:doctor`. Spec
   author chose bare because these are the two commands operators use to discover all
   other commands; colon-prefixing them adds friction at the most critical discovery moment.

2. **`/sessions` → `/session:list` (not `/session:sessions`).** The primary form
   `/sessions` is a list action; the colon form normalizes to the verb `list`.

3. **`/actors` → `/actor:list`.** The singular `actor` group name is used; the yaml uses
   `category: "诊断"` but the group is functionally `actor`.

4. **`/key` → `/session:key`.** The `/key` command sends keystrokes to the PTY of the
   session currently bound to the chat. Group is `session` because the target is always
   a session's PTY.

5. **`/workspace sessions` → `/workspace:sessions` (not `/session:list workspace=<n>`).** This
   preserves the semantic distinction: `/session:list` lists sessions for the current chat's
   bound workspace, while `/workspace:sessions` takes an explicit workspace argument.

6. **`@deprecated_slashes` lifetime: one release minimum, removal by separate PR.** The
   spec does not set a hard deadline for removal; a follow-up PR titled
   `chore: remove deprecated_slash map` is the intended removal vehicle.
