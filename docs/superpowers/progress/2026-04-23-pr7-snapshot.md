# PR-7 Snapshot — e2e scenarios feishu-to-cc merged

**Date**: 2026-04-23 (continuation of same-day 7-PR refactor push)
**PR**: [ezagent42/esr#22](https://github.com/ezagent42/esr/pull/22)
**Merge commit**: `ce76238`
**Duration**: brainstorm (8 Feishu rounds) + spec v1.0→v1.1 + plan v1.0→v1.1 + 14 task commits + 2 reconciliation commits = full subagent-driven cycle

## Shipped

### New test infrastructure

- **`tests/e2e/scenarios/`** — three bash scenario scripts covering the 12-step feishu-to-cc business topology:
  - `01_single_user_create_and_end.sh` — new-session → text → react → send_file → end-session
  - `02_two_users_concurrent.sh` — two users A+B with session-isolation barriers
  - `03_tmux_attach_edit.sh` — tmux pane attach + capture + edit + detach (isolated socket)
- **`tests/e2e/scenarios/common.sh`** — shared preamble: env bootstrap, assertion helpers (assert_eq / assert_contains / assert_mock_feishu_* / assert_tmux_pane_contains), barrier primitives (barrier_signal / barrier_wait), trap-based teardown, one-shot setup helpers (start_mock_feishu / load_agent_yaml / start_esrd / register_feishu_adapter).
- **`tests/e2e/scenarios/_common_selftest.sh`** — smoke test for common.sh itself.
- **`tests/e2e/fixtures/probe_file.txt`** — 1 KB probe for send_file round-trip.

### Architectural fixes (the real work)

- **`channel_adapter` threaded end-to-end (D1 + D2)**: `SessionRouter.do_create/1` parses `proxies[].target` via regex `~r/^admin::([a-z0-9_]+)_adapter_.*$/` (widened from `[a-z_]+` to include `slack_v2`) → PeerFactory ctx map → `FeishuChatProxy.init/1` lifts into thread-state map → `PeerServer.build_emit_for_tool/3` consumes `session_channel_adapter(state)`. Eliminates three `"adapter" => "feishu"` literals that violated the CC-channel-adapter-agnostic invariant.
- **`react` directive `message_id` → `msg_id`** (D2): aligns with `_pin`, `_unpin`, `_download_file` conventions in adapter.py.
- **`send_file` directive α base64 in-band** (D2 + C): `{chat_id, file_name, content_b64, sha256}`. Adapter.py `_send_file` handler decodes, re-encodes to lark_oapi `POST /open-apis/im/v1/files` + `POST /messages` with `msg_type: "file"`.
- **`tmux_socket` env override** (J1): scripts export `ESR_E2E_TMUX_SOCK` → `Esr.Application.start/2` reads → `Application.put_env(:esr, :tmux_socket_override, ...)` → `TmuxProcess.spawn_args/1` merges.

### Mock Feishu extensions (B)

- `POST /open-apis/im/v1/messages/:message_id/reactions` + `GET /reactions` for reaction assertions.
- `POST /open-apis/im/v1/files` (multipart/form-data + JSON base64) for file upload, `GET /sent_files` for sent-file assertions, `POST /open-apis/im/v1/messages` with `msg_type: "file"` links files to chats.

### Adapter-agnostic sanitization (K1 + K2)

- `adapters/cc_mcp/src/esr_cc_mcp/tools.py` — 6 "Feishu" mentions rewritten adapter-agnostic (e.g., "Send a file to the chat" instead of "Send a file to the Feishu chat").
- `runtime/lib/esr/peers/cc_proxy.ex` + `cc_process.ex` — docstring references to `FeishuChatProxy` generalized.
- §13 acceptance grep `grep -irn 'feishu' adapters/cc_mcp/src/ runtime/lib/esr/peers/cc_*.ex runtime/lib/esr/peers/cc_proxy.ex runtime/lib/esr/peers/cc_process.ex` → **0 matches**.

### CLI extension (H)

- `EsrWeb.CliChannel.dispatch/2` accepts `{"field": "state.session_name"}` payload, returns `{"data": {"value": "esr_cc_42"}}`. Python CLI `esr actors inspect <id> --field state.session_name` plumbing added.

## Regression status at merge

| Suite | Result |
|---|---|
| `mix test` | **427 tests, 0 failures** (21 excluded) |
| `pytest py/tests/` | **452 passed**, 1 skipped |
| §13 combined grep | **0 matches** (from baseline 8) |

## Deliberately NOT verified in automation

- **`make e2e` full run** — the three bash scenarios require live `esrd` + `mock_feishu` + real `tmux` + Python sidecar spawns. The orchestrator committed the scripts but did not execute them in the automated flow to avoid interfering with the user's dev environment. All backing unit tests that prove the directive shapes, channel_adapter plumbing, and CLI introspection ARE green, so the scripts should work on first real-hardware run. User will smoke-test `make e2e` locally.

## Commits (14 on top of PR-6 snapshot `4edf23d`)

| SHA | Task | Title |
|---|---|---|
| `484a8b2` | T0 | docs(notes): PR-7 frozen wire contracts |
| `c85755c` | A | feat(e2e): common.sh preamble + probe_file fixture |
| `81a56df` | B | feat(mock_feishu): reactions + file upload endpoints |
| `31365aa` | C | feat(esr_feishu): _send_file + _react mock branches |
| `e48b294` | K1 | refactor(cc_mcp): sanitize tool descriptions — adapter-agnostic |
| `6c65def` | K2 | refactor(peers): drop FeishuChatProxy literals from CC peer docs |
| `94c433e` | D1 | feat(session_router): plumb channel_adapter end-to-end |
| `61abdf6` | D2 | feat(peer_server): consume channel_adapter + fix msg_id bug + α send_file |
| `4ca73a3` | J1 | feat(application): ESR_E2E_TMUX_SOCK → :tmux_socket_override |
| `cdddeb5` | F | feat(e2e): scenario 01 — single-user create/react/send_file/end |
| `f1b4db4` | G | feat(e2e): scenario 02 — two-user concurrent isolation |
| `7cac12d` | H | feat(e2e): scenario 03 + cli:actors/inspect --field |
| `5c5c944` | I | build: make e2e / e2e-ci targets + CI-mode cleanup |
| `c34b386` | J | docs(e2e): README for tests/e2e |
| `b9e5197` | reconcile | fix: reconcile regressions from Task C adapter extensions |
| `f37ae82` | reconcile | fix(test): tolerate exited PeerServer in Task H on_exit cleanup |

Squash-merged to `main` as `ce76238` (PR #22).

## Plan drift accommodated (all documented in commit messages)

- **Task B tests**: switched from `urllib.request.urlopen` to `aiohttp.ClientSession` — urlopen deadlocked against an in-process aiohttp mock on the same event loop.
- **Task C `on_directive`**: `send_file` + `react` mock paths dispatch through `run_in_executor` (parity with `_deny_rate_limited`). Added `base64` + `hashlib` to the adapter's `allowed_io` (decorator + `esr.toml` manifest).
- **Task D1 regex**: `[a-z_]+` → `[a-z0-9_]+` to match the plan's own `slack_v2` test case.
- **Task D1 FeishuChatProxy.init/1**: used `Map.put` instead of a mixed-key literal (Elixir disallows `key:` shorthand + `"key" =>` in the same map).
- **Task H test fixture**: `Esr.PeerServer.start_link(initial_state: …)` instead of `GenServer.start(… state: …)` — matches actual `init/1`'s `Keyword.get(opts, :initial_state, …)`. Also wrapped on_exit `GenServer.stop` in try/catch.
- **Task H `get_in_nested`**: `String.to_existing_atom` + rescue instead of `String.to_atom` so unknown keys don't crash the lookup.
- **Reconciliation commits**: `py/tests/test_cli_actors.py` updated for the new `field=None` kwarg; `adapters/feishu/esr.toml` mirrored the decorator's widened `allowed_io`.

## 8-PR refactor summary (PR-0 through PR-7)

| PR | Focus | Merge commit |
|---|---|---|
| PR-0 | SessionRouter → SlashHandler rename | `bd79f7f` |
| PR-1 | Peer behaviours + OSProcess底座 | `155bc56` |
| PR-2 | Feishu chain + AdminSession | `fcef9e3` |
| PR-3 | CC chain + SessionRouter + Topology removal | `a416a25` |
| PR-4a | Voice-gateway split | `2e3106c` |
| PR-4b | adapter_runner.py → 3 per-type sidecars | `ab86a62` |
| PR-5 | Shim hard-delete + IPC consolidation + warnings-clean | `f116fad` |
| PR-6 | Simplify pass (ETS + persistent_term; p99 7µs → 2µs) | `7d296a2` |
| **PR-7** | **E2E scenarios + channel_adapter plumbing** | **`ce76238`** |

**End state**: 452 pytest + 427 mix test green. CC-channel-adapter-agnostic invariant proven (§13 grep = 0). e2e script scaffolding ready for first user-run.
