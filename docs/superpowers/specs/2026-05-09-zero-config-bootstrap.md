# Zero-config bootstrap for esr CLI

**Spec id:** 2026-05-09-zero-config-bootstrap
**Author:** Allen Woods + Claude
**Status:** rev-2 (post subagent code-review 2026-05-09)
**Tracks:** post-multi-instance audit step #2 (auto-admin) follow-up

## 0. rev-2 changelog (2026-05-09 post code-review)

Three structural bugs in rev-1 surfaced + several minor concerns:

- **B1.** rev-1 referenced `Esr.Admin.Dispatcher.cap_check/2`. **No such module exists.** The cap-check site is `Esr.Entity.SlashHandler.handle_cast({:dispatch_command, ...})` at `runtime/lib/esr/entity/slash_handler.ex:323-368`, the inline guard around `Esr.Resource.Capability.has?/2` at line 355. § 3.2 + § 4 file-changes table updated.
- **B2.** rev-1's `:bootstrap` atom across the wire is impossible. CLI submits to the admin queue via **YAML files** (`runtime/lib/esr/cli/main.ex:262-286` writes the queue file; `Esr.Slash.QueueWatcher` at `queue_watcher.ex:182-190` parses with YamlElixir). Atoms don't survive YAML round-trip. The sentinel becomes the **reserved string `"system:bootstrap"`**. The "cannot be poisoned via yaml grant" property D1 leans on is preserved by:
  - `Esr.Resource.Capability.FileLoader.validate_entry/1` rejecting any principal entry whose `id` matches the sentinel string.
  - `Esr.Commands.Cap.Grant` rejecting `principal_id == sentinel` at submit time.
  Both checks are implementation surface of D1, listed in § 4 + § 7.
- **B3.** rev-1's `esr user use <name>` collides with the existing `/user:use workspace=…` slash. The CLI sub-action concatenation at `cli/main.ex:186-200` turns `esr user use linyilun` into `kind: user_use`, which already maps to `Esr.Commands.User.Use` (sets per-user default workspace). New verb: **`esr user switch <name>`** → `kind: user_switch`. § 3.6 updated.

Minor adjustments:

- § 3.2 explicitly carves out: "do NOT extend `Capability.has?/2` to recognise the sentinel; the bypass lives in the slash_handler check site only".
- § 3.3: ETS-only `any_admin?/0` has a race window if `capabilities.yaml` is wiped on-disk while ETS still holds `*` from a prior session. Mitigation: spec defers — Watcher reload (FSEvents on disk wipe) flushes ETS within 1-2s; sentinel re-activates after the FSEvents tick. Acceptable for the documented "wipe and restart" workflow (the wipe script also stops the daemon). Spec'd as Open Question #1 below.
- § 3.7 telemetry event renamed to `[:esr, :slash, :bootstrap_bypass]` for prefix-consistency with the actual dispatch-site module.
- § 5 D5 reframed: `ESR_BOOTSTRAP_PRINCIPAL_ID` env var produces a `kind: feishu_user` capabilities.yaml entry (pre-this-PR), while sentinel + auto-admin produces `kind: esr_user`. Two parallel seed shapes co-exist; spec acknowledges + defers reconciliation to a future deprecation PR.

## 1. Problem statement

After PR #281 shipped first-user-auto-admin, the operator's CLI journey still requires two env-var hacks:

1. `ESR_BOOTSTRAP_PRINCIPAL_ID` to seed `capabilities.yaml` at first esrd boot (else cap table is empty).
2. `ESR_OPERATOR_PRINCIPAL_ID` so esr CLI's submitter is anything other than the no-cap default `"ou_unknown"`.

Without (1), the very first `user_add` admin-queue submit hits cap-check failure (`unauthorized`, required `user.manage`).
Without (2), every CLI command submits as `"ou_unknown"` which holds no caps.

The user-stated mental model is:
- esr user (linyilun) is the canonical CLI identity, independent of any IM (Feishu).
- Feishu open_id (`ou_xxx`) is a binding link, not a principal — it lives in the feishu plugin domain.
- The operator journey starts with creating the esr user, then registering adapters, then binding.

The current implementation conflates these by making feishu open_id the bootstrap principal.

## 2. Goal

Operator can run a fresh-install esr CLI journey **with zero env vars and zero pre-edits** to any yaml/json:

```bash
cd /Users/.../.worktrees/dev
alias esr-dev='ESRD_HOME=$HOME/.esrd-dev ESR_INSTANCE=default ESR_HOST=127.0.0.1:4001 ./runtime/esr'
esr-dev exec user_add --name=linyilun
esr-dev exec register_adapter --type=feishu --name=esr_helper_dev --app_id=cli_xxx --app_secret=xxx
esr-dev exec feishu_bind --name=linyilun --ou_id=ou_xxx
```

No `ESR_BOOTSTRAP_PRINCIPAL_ID`. No `ESR_OPERATOR_PRINCIPAL_ID`. No yaml hand-editing.

## 3. Design

### 3.1 The `"system:bootstrap"` sentinel string

A reserved principal_id string `"system:bootstrap"`. Carried in the admin-queue envelope's `submitted_by` field exactly like any other principal_id (no atom serialisation gymnastics).

Why a reserved string + not yaml-poisonable:

- `Esr.Resource.Capability.FileLoader.validate_entry/1` rejects any `principals[].id == "system:bootstrap"` at load time → the string can never appear as a granted admin in capabilities.yaml.
- `Esr.Commands.Cap.Grant.execute/1` rejects `args.principal_id == "system:bootstrap"` at submit time → operator can't type `cap_grant principal_id=system:bootstrap permission=*` to backdoor.
- The ONLY route to "bypass cap check using this string" is § 3.2's three-condition guard at the slash-handler dispatch site.

The `system:` namespace prefix is reserved for runtime sentinels going forward (extensible to e.g. `system:health-probe` if needed).

### 3.2 Sentinel scope (cap-bypass conditions)

The cap-check at `runtime/lib/esr/entity/slash_handler.ex:355` (the call to `Esr.Resource.Capability.has?/2` inside `handle_cast({:dispatch_command, ...})`) is preceded by a guard. Bypass when **all three** are true:

1. `submitted_by == "system:bootstrap"`
2. `kind in @bootstrap_allowed_kinds` (initial set: `["user_add"]` only)
3. `Esr.Resource.Capability.Grants.any_admin?/0 == false`

Any one missing → normal `Capability.has?/2` call.

`@bootstrap_allowed_kinds` is a compile-time list, not config. Currently `["user_add"]`. Future expansion (e.g. for `register_adapter` when adapter-grant model changes) requires a code change + spec update.

**Carve-out:** the bypass logic lives ONLY in slash_handler. `Esr.Resource.Capability.has?/2` (`runtime/lib/esr/resource/capability.ex:32-45`) does NOT learn about the sentinel — it remains a simple "look up principal in ETS, match" function. Centralising the sentinel in one place keeps the cap-bypass attack-surface auditable.

### 3.3 Sentinel deactivation

Once `Grants.any_admin?/0` returns true (after first user_add + auto-admin in PR #281), the third bypass condition fails permanently for the lifetime of this capabilities.yaml. Sentinel becomes a no-op — submitting `:bootstrap` for any kind returns `unauthorized`.

If someone wipes capabilities.yaml manually (or the file becomes unreadable + Grants ETS drains), sentinel re-activates. This matches the existing `ESR_BOOTSTRAP_PRINCIPAL_ID` env behavior (which only seeds if file is missing).

### 3.4 `operator.json` — the active-operator state file

New file: `<ESRD_HOME>/<instance>/operator.json`. Schema:

```json
{
  "schema_version": 1,
  "principal_id": "<user_uuid_v4>",
  "name": "<username>",
  "set_at": "<iso8601>",
  "set_by": "user_add" | "user_use" | "manual"
}
```

Written by:
- **`Esr.Commands.User.Add.maybe_grant_admin/1`** (extended): after auto-admin grants `*`, also write operator.json with the new user's uuid + name. `set_by: "user_add"`.
- **`Esr.Commands.User.Switch`** (new — see § 3.6): on success, overwrite operator.json. `set_by: "user_use"`.
- The operator manually (vim/echo): `set_by` is informational; only `principal_id` + `name` are load-bearing.

Read by:
- **esr CLI** (escript): in submitter resolution (§ 3.5).

### 3.5 esr CLI submitter resolution

`runtime/lib/esr/cli/main.ex` — new function `resolve_submitter/0` replacing the env-var read at line 274. Resolution chain (first match wins):

1. **`operator.json`** at `<ESRD_HOME>/<instance>/operator.json` — read `principal_id` field. If file exists but malformed → log warning, fall through.
2. **Sentinel `"system:bootstrap"`** — passed as `submitted_by` in the queue envelope (regular YAML string, no special encoding). CLI prints `using bootstrap sentinel (no operator configured)` to stderr so operator knows.

**No `ESR_OPERATOR_PRINCIPAL_ID` env var support.** Hard cutover. (User decision 2026-05-09.) Scripts that previously set this env var must instead `echo '{...}' > operator.json` or invoke `esr user switch` first.

The CLI's existing help-text reference to `ESR_OPERATOR_PRINCIPAL_ID` (`cli/main.ex:566`) is removed in this PR.

### 3.6 `user_switch` command

New internal_kind `user_switch` (CLI-only, no slash entry — switching the active CLI operator from a Feishu envelope makes no semantic sense; envelopes always identify the operator from inbound user_id).

Module: `Esr.Commands.User.Switch` (module sibling of `User.Add`, `User.Use`, `User.Remove`).

Args: `name` (required, string). Resolves to user UUID via `User.NameIndex`, validates user exists, writes operator.json with `set_by: "user_switch"`.

Permission: `user.manage` (consistent with user_remove). Sentinel does NOT bypass this — switching active user requires being admin.

Returns `{:ok, %{"action" => "switched", "username" => name, "principal_id" => uuid}}`.

CLI helper: `esr user switch <name>` maps to `esr exec user_switch --name=<name>` (PR-2.6 already supports the `esr <head> <sub-action>` → kind translation via `cli/main.ex:186-200`). Operator habit:

```bash
esr-dev user switch yaoshengyue
```

**Why not `esr user use`** — `kind: user_use` is already taken by `Esr.Commands.User.Use` (sets per-user default workspace, slash `/user:use workspace=…`). CLI sub-action concatenation maps `esr user use linyilun` to `kind: user_use`, which would route to the workspace-default command and fall through to `invalid_args` (no `workspace` key). Spec rev-1 had this collision; rev-2 picks the unambiguous verb `switch`.

### 3.7 Sentinel observability

Each sentinel-bypass dispatch logs `Logger.info("slash_handler: bootstrap-sentinel bypass for kind=#{kind} (no admin yet)")`. Telemetry event `[:esr, :slash, :bootstrap_bypass]` for ops dashboards. (Prefix is `:slash` to match the actual dispatch-site module — rev-1 said `:admin` which doesn't exist.)

## 4. File changes

| File | Change |
|---|---|
| `runtime/lib/esr/entity/slash_handler.ex` | Add bootstrap-sentinel branch in cap-check at line 355 (before `Capability.has?/2` call). 3-condition guard per § 3.2. Logger + telemetry per § 3.7. |
| `runtime/lib/esr/resource/capability/file_loader.ex` | `validate_entry/1` rejects `id == "system:bootstrap"` (sentinel can't be granted in yaml). |
| `runtime/lib/esr/commands/cap/grant.ex` | Reject `args.principal_id == "system:bootstrap"` at submit time. |
| `runtime/lib/esr/commands/user/add.ex` | `maybe_grant_admin/1` also writes operator.json |
| `runtime/lib/esr/commands/user/switch.ex` (new) | `Esr.Commands.User.Switch` writes operator.json |
| `runtime/priv/slash-routes.default.yaml` | Add `internal_kinds.user_switch` entry (no slash) |
| `runtime/lib/esr/cli/main.ex` | New `resolve_submitter/0`; remove `ESR_OPERATOR_PRINCIPAL_ID` reading |
| `runtime/lib/esr/paths.ex` | Add `Esr.Paths.operator_json/0` helper |
| `runtime/test/esr/admin/dispatcher_test.exs` | Bootstrap-bypass tests (3 conditions, on/off) |
| `runtime/test/esr/commands/user/add_test.exs` | Extend auto-admin test to assert operator.json written |
| `runtime/test/esr/commands/user/switch_test.exs` (new) | switch happy path + invalid name |
| `runtime/test/esr/cli/main_test.exs` (or escript test) | submitter resolution chain |
| `tests/e2e/scenarios/23_zero_config_bootstrap.sh` (new) | wipe → user_add → register_adapter → feishu_bind |

Estimate: ~150 LOC implementation + ~120 LOC tests + 100 LOC e2e + 80 LOC docs.

## 5. Decisions

- **D1.** Sentinel is the reserved string `"system:bootstrap"` (rev-2 fix to rev-1's atom claim). Rationale: the CLI→queue→dispatcher transport is YAML files, not in-memory message-passing — atoms can't survive the round-trip. The "cannot be poisoned via yaml grant" property is preserved by validators rejecting the string at `cap_grant` and `FileLoader` levels (§ 4).
- **D2.** Bypass scope is `[:user_add]` only. Rationale: smallest attack surface; PR #281's `maybe_grant_admin/1` already promotes the new user to real admin, so subsequent commands run with normal cap check.
- **D3.** `ESR_OPERATOR_PRINCIPAL_ID` env var support removed. Hard cutover. Rationale: env-var workflows mask design intent; operator.json is the single source of truth (user decision 2026-05-09).
- **D4.** `user_switch` is CLI-only (no slash). Rationale: Feishu envelopes resolve operator from inbound `user_id`; no concept of "active operator" applies in that surface.
- **D5.** `ESR_BOOTSTRAP_PRINCIPAL_ID` env var STAYS as a complementary boot-time seed mechanism. Rationale: pre-existing dev environments may rely on it; changing two env vars in one PR is too aggressive. Spec 2026-05-10+ may deprecate.

## 6. Migration impact

- **Dev environment**: dev plist's `ESR_BOOTSTRAP_PRINCIPAL_ID=ou_xxx` continues to work (D5 — keeps capabilities.yaml seeded with feishu admin). Spec changes do not break it.
- **Existing operators with `ESR_OPERATOR_PRINCIPAL_ID` exported**: their export silently no-ops post-this-PR. CLI falls through to operator.json or sentinel. **Documented as breaking change in PR description.**
- **CI / automation scripts**: must replace env-var export with `operator.json` write OR `user_use` CLI call.

## 7. Test plan

### Invariants (verified by tests)

- **I1.** Sentinel bypass fires only when all 3 conditions hold; failure of any one returns `unauthorized`.
- **I2.** First `esr-dev exec user_add --name=alice` (no env vars, no operator.json) creates alice + grants admin + writes operator.json + sentinel deactivates.
- **I3.** Second `esr-dev exec user_add --name=bob` (operator.json now points to alice) creates bob without auto-admin (alice's caps used).
- **I4.** `esr-dev user use bob` writes operator.json switching active operator.
- **I5.** `ESR_OPERATOR_PRINCIPAL_ID` env var in environment is ignored (no dispatch effect).
- **I6.** `e2e scenario 23` exercises the full zero-config journey end-to-end.

### Test sequencing

Unit:
1. Dispatcher: 4 cases for bypass conditions (all-3-true → bypass; each-1-false → unauthorized).
2. User.Add: extended test asserting operator.json is written + readable post-add.
3. User.Switch: happy path + invalid name + permission denied (non-admin caller).
4. CLI submitter resolution: 3 cases (operator.json present → uuid; absent → sentinel; ESR_OPERATOR_PRINCIPAL_ID set → still goes to step 1 of chain, env ignored).

E2E (scenario 23):
- wipe → restart esrd-dev (no env)
- `esr-dev exec user_add --name=alice` → ok + auto_admin: true
- assert operator.json exists with alice's uuid
- `esr-dev exec register_adapter --type=feishu ...` → ok (cap from auto-admin)
- `esr-dev exec feishu_bind --name=alice --ou_id=ou_xxx` → ok
- `esr-dev exec user_list` → shows alice with feishu binding

## 8. Open questions resolved + remaining

Resolved (rev-1 brainstorm 2026-05-09):
- **Q1.** Sentinel scope: `"user_add"` kind only (D2).
- **Q2.** Sentinel value: reserved string `"system:bootstrap"` (D1, post rev-2 fix).
- **Q3.** Post-bootstrap submitter: `operator.json` only; ESR_OPERATOR_PRINCIPAL_ID env REMOVED (D3, user decision).

Remaining (rev-2 surfaced):
- **Q4.** ETS-vs-disk race for `any_admin?/0`: if operator wipes capabilities.yaml on-disk but ETS still holds `*` from a prior boot, sentinel doesn't re-activate until the FSEvents Watcher reloads (1-2s). Acceptable for documented "wipe + restart daemon" workflow (the wipe script stops the daemon, killing ETS). Tracked as a known limitation; no action this PR.
- **Q5.** Two parallel capability seed shapes: `ESR_BOOTSTRAP_PRINCIPAL_ID` writes `kind: feishu_user`; sentinel + auto-admin writes `kind: esr_user`. A future PR may deprecate the env-var path entirely. Not done here (D5 keeps env path for back-compat).

## 9. Out-of-scope (future)

- `esr admin bind-principal` to migrate from feishu_user→esr_user identity (per `docs/futures/admin-principal-id-bind-cli.md`).
- Multi-operator desktop UX (operator.json swap UI). Currently operator either runs `esr user use` or hand-edits the file.
- Deprecation of `ESR_BOOTSTRAP_PRINCIPAL_ID` env var (deferred per D5).

---

User-approved 2026-05-09. Ready for implementation plan.
