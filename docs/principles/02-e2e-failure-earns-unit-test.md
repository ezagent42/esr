# 02. Every distinct e2e failure mode earns a unit or integration test

## Statement

When an e2e run surfaces a bug, capture it as a unit or integration
test before (or alongside) the production fix. The test should fail
before the fix and pass after — documenting both the regression shape
and the fix scope.

## Why

E2E runs are expensive: live `esrd` + mock Feishu + tmux isolation +
Python sidecars add up to minutes per run. Unit tests are seconds.
Funneling each distinct e2e failure through a targeted unit test
makes the codebase monotonically more resilient without making the
e2e feedback loop slower.

There is also a subtler win: writing the test often clarifies the
fix. If the failure shape is hard to express as a test, the root
cause isn't well-understood yet — a sign to think longer before
changing code.

## How to apply

- When an e2e step fails and the cause is a non-trivial bug, add a
  unit or integration test first, then make the fix.
- The test should be at the tightest scope that reproduces the
  failure: prefer unit over integration, integration over e2e.
- Flaky or order-dependent failures are tests too — they may need
  `async: false`, specific setup patterns, or careful process
  isolation.
- The inverse principle: if an e2e keeps flaking and a unit test
  doesn't exist, writing the unit test is a forcing function for
  root-cause analysis.

## Concrete examples (PR-7 `make e2e` debugging, 2026-04-23)

| e2e symptom | Unit/integration test added |
|---|---|
| `register_adapter` crashed with "ETS table identifier does not refer to an existing ETS table" because admin watcher's orphan recovery ran before `EsrWeb.Endpoint` was up | `runtime/test/esr/admin/commands/register_adapter_test.exs` — "default_adapter_ws_url/0 survives Endpoint ETS absence" |
| `mock_feishu.py --port 8201` stuck holding the port after teardown (uv wrapper / python child pid mismatch) | `py/tests/scripts/test_mock_feishu_teardown.py` — the defensive `pkill -f "mock_feishu.py --port N"` frees the port within 5s |
| SlashHandler not reachable via `AdminSessionProcess.slash_handler_ref/0` in production (tests manually `start_supervised/1`) | `runtime/test/esr/admin_session_slash_handler_boot_test.exs` — asserts a live pid after app boot without manual setup |
| `agents.yaml` dropped at instance root wasn't auto-loaded | Existing integration tests (n2_sessions_test, cc_e2e_test) now rely on the boot-time `load_agents_from_disk/0` path |

Each test guards a specific regression. Together they prevent the
infrastructure fixes from silently eroding.

## Cross-refs

- Memory: `feedback_e2e_failure_earns_unit_test.md`
- User feedback (2026-04-23 Feishu): "E2E 不能通过的步骤，要考虑在 unittest 加入，提前发现问题所在"
