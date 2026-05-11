# SessionTemplate + Channel — 飞书侧测试指南

> **配套文件:** [`.zh_cn.md`](flow-sessiontemplate-feishu-test.zh_cn.md)
> **Spec:** [`docs/superpowers/specs/2026-05-10-session-template-and-channel.md`](../superpowers/specs/2026-05-10-session-template-and-channel.md)
> **Plan:** [`docs/superpowers/plans/2026-05-10-session-template-and-channel-plan.md`](../superpowers/plans/2026-05-10-session-template-and-channel-plan.md)
> **PR series:** #324 → #325 → #326 → #327 → #328 → #329 → #330 → #331

This guide walks an operator through testing the SessionTemplate + Channel
migration end-to-end via Feishu chat. CLI-side config is already in place;
this doc documents the reproduction steps + the verification points.

## Prerequisites

CLI-side state is already migrated for the `~/.esrd-dev/default/` instance
(operator: `linyilun`, principal `f813b071-…`):

- `operator.json` — `caller_principal_id` (post-#321 schema)
- `adapters/esr_helper_dev/config.yaml` — yaml-v2 per-thing-dir layout (post-#322)
- `plugins/{claude_code,feishu}/config.yaml` — yaml-v2 plugin config
- `plugins.yaml` — `enabled: [claude_code, feishu]`
- esrd-dev running, feishu sidecar attached

If you start over from a fresh install, the existing
[`operator-bootstrap-checklist.md`](operator-bootstrap-checklist.md) covers
steps 1–7; the new SessionTemplate-specific verification starts at step 8
below.

## What changed (operator surface)

The **only** new operator-visible surface vs the rev-5 checklist:

| Surface | Before | After |
|---|---|---|
| `/session:new` args | `name=foo agent=cc` | `name=foo template=feishu-cc` (new arg; default auto-elects when single template registered) |
| New slash | — | `/agent:add-session session=<sid> name=<n>` (multi-session-per-instance) |
| New mix tasks | — | `mix esr.gen_bundle_docs`, `mix esr.check_bundles` (CI gate) |
| Agent persistence | embedded in `session.json::agents[]` | per-file `sessions/<sid>/agents/<uuid>.json` (boot-time auto-migration) |

Everything else (workspace flow, /agent:add, plain text → CC reply) is
unchanged.

## Test steps

### 8a. Verify bundle + template registered

In the Feishu chat that has the bot:

```
/plugin:list
```

Expect: rows for `claude_code` (enabled), `feishu` (enabled), `stub_agent`
(disabled — Phase 8 stub bundle for the abstraction-validation e2e).

(Bundle registration verification is internal — there's no `/bundle:list`
slash today; verifies via `/session:new template=` resolving the name.)

### 8b. Workspace + session via template

```
/workspace:new name=test-ws
/workspace:add-folder path=/Users/h2oslabs/Workspace/esr
/session:new name=test-cc template=feishu-cc
```

Expect:
- `/workspace:new` returns `ok: true`
- `/workspace:add-folder` returns `ok: true` (path must be a real git repo)
- `/session:new` returns `ok: true` with the new template-driven materialization

If `template=` is omitted, Phase 5's `Esr.Session.DefaultTemplate.auto_elect_if_single/0`
auto-elected `feishu-cc` at boot (since it's the only registered template),
so plain `/session:new name=test-cc` should also work.

### 9. Add CC agent

```
/agent:add type=cc name=alice
```

Expect: `ok: true` with `actor_ids.cc` + `actor_ids.pty` populated.

### 10. Plain text → CC reply

In the same chat:

```
hello, what's the cwd?
```

Expect: Claude Code replies with the actual working directory.

### 11. Multi-session-per-instance (new in Phase 7)

In a SECOND Feishu chat with the same bot:

```
/workspace:use name=test-ws
/session:new name=test-cc-junior
/agent:add-session session=<test-cc-junior's_sid> name=alice
```

Expect:
- alice's `session_ids` array now contains both sessions' UUIDs
- Inspect on disk:
  ```bash
  cat ~/.esrd-dev/default/sessions/<sid_A>/agents/<alice_uuid>.json | jq .session_ids
  ```
  shows `[<sid_A>, <sid_B>]`.
- Send `hello from junior` in the second chat; reply lands in the second chat
  only (NOT cross-leaked to the boss chat). Reply routing follows the
  inbound `current_session_id`.

### 12. PTY attach (unchanged)

```
/claude_code:tui name=alice
```

Returns the signed `?token=` URL; opens xterm.js attached to alice's PTY.

## Verification points

These are the **invariants** Phase 1-8 promised:

- [ ] `/session:new template=feishu-cc name=foo` succeeds without `agent=`
      arg (template carries the agent_kind)
- [ ] `/session:new name=foo` (no `template=`) also succeeds — default
      auto-elected from single registered template
- [ ] Two sessions + one agent via `/agent:add-session` — replies route to
      the right chat (no cross-talk)
- [ ] On-disk: `sessions/<sid>/agents/<uuid>.json` per-file layout (Phase 7
      hardcut from `agents:[]` array)
- [ ] `mix esr.check_bundles` CI gate green (in `runtime/`)

## Troubleshooting

### "esr: operator.json malformed"

The `principal_id` field was renamed to `caller_principal_id` in #321
(2026-05-09). If you migrated an old `~/.esrd-dev/`, edit `operator.json`
and rename the field. CLI re-reads on every invocation — no restart needed.

### "no template registered"

`Esr.SessionTemplate.Registry.list_all/0` is empty. Check:
1. `bundles_dir` resolution — `Esr.Paths.bundles_dir/0` should return
   `runtime/lib/esr/bundles/` (Phase 8 fix). If you're on a Phase 7-or-older
   build, the path was wrong; restart on a post-#331 build.
2. The bundle's `dependencies.plugins[]` are all enabled (feishu-cc needs
   both `feishu` AND `claude_code`).
3. Logs: `tail -50 ~/.esrd-dev/default/logs/launchd-stderr.log` should not
   show `Logger.warning` about template skip due to missing plugin.

### `unknown_kind: plugin:list`

The `:` form is the slash form (chat-side). For CLI use the kind name:
`esr-dev exec plugin_list` (snake_case), not `exec /plugin:list`.

### Agent reply lands in wrong chat (multi-session)

The Phase 7 invariant test
(`runtime/test/esr/plugins/claude_code/cc_process_multi_session_test.exs`)
pins this. If observed in production, the bug is likely in
`CCProcess`'s `current_session_id` extraction from the inbound envelope.
Check that the inbound `notification` carries the `current_session_id`
field (Phase 7 task 7.6 added it to the cc_mcp tool catalog).

## Acceptance — final checklist

After running the steps above, the 8-phase migration is operator-verified:

- ✅ Phase 1-3: Channel behaviour + 2 impls registered (verified by
      `/plugin:list` showing claude_code + feishu enabled with channels)
- ✅ Phase 4: Bundle + SessionTemplate registries; first bundle `feishu-cc`
      auto-loaded
- ✅ Phase 5: `/session:new template=` cutover + auto-elect default
- ✅ Phase 6: agents.yaml gone; `agent_kinds:` source-of-truth in plugin
      manifests
- ✅ Phase 7: per-instance JSON files; multi-session-per-instance via
      `/agent:add-session`
- ✅ Phase 8: `mix esr.check_bundles` CI gate; stub plugin proves the
      abstraction isn't CC-specific

If any step above fails, capture `~/.esrd-dev/default/logs/launchd-stderr.log`
+ the failing slash + a `cat ~/.esrd-dev/default/sessions/<sid>/session.json`
output, and report.
