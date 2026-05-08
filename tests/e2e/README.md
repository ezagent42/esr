# PR-7 end-to-end scenarios

Three bash scripts + shared preamble that exercise the Feishu → CC
business topology against a running `esrd` + `scripts/mock_feishu.py`.

## Running

```bash
make e2e       # all three scenarios, dev-mode cleanup
make e2e-01    # just scenario 01 (single user)
make e2e-02    # just scenario 02 (two users concurrent)
make e2e-03    # just scenario 03 (tmux attach/edit)
make e2e-ci    # CI-mode: absolute cleanup after (pkill + tmux kill-server)
```

Each recipe has a `timeout 300` wrapper so a hung esrd cannot hold CI.

## Structure

| File | Purpose |
|------|---------|
| `scenarios/common.sh` | Env bootstrap, assertion helpers, barrier primitives, trap-based teardown. All three scripts source it. |
| `scenarios/01_single_user_create_and_end.sh` | §9 user-steps 1-6 + 12. Create session, plain message, react, send_file, second message, end. |
| `scenarios/02_two_users_concurrent.sh` | §9 user-steps 7-8. Two bash subshells with barrier-sync'd probes; asserts cross-session isolation. |
| `scenarios/04_multi_app_routing.sh` | Cross-app forward — `app_id` propagation, capability denial. |
| `scenarios/05_topology_routing.sh` | `<channel reachable=…>` + BGP-style reachable_set learn. |
| `scenarios/06_pty_attach.sh` | PTY actor attach — xterm WS frames; PR-22 canonical green anchor. |
| `scenarios/07_pty_bidir.sh` | PTY actor bidirectional — keystroke → process → frame round-trip. |
| `scenarios/16_plugin_config_layers.sh` | Plugin config 3-layer merge (global < user < workspace). |
| `scenarios/17_plugin_config_hot_reload.sh` | HR-4: hot-reload env propagation via mock-claude binary. Proves `plugin_set` + `plugin_reload` + agent restart delivers updated `HTTP_PROXY` to new subprocess. No real Anthropic API needed. |
| `fixtures/probe_file.txt` | 1 KB probe for `send_file`. |
| `fixtures/mock-claude.sh` | Synthetic claude binary for scenario 17. Echoes env state to a side-channel dump file on startup. |
| `scenarios/_common_selftest.sh` | Self-test for `common.sh`; run in CI before the real scenarios. |

## Design spec

`docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md`

## Wire contracts

`docs/notes/pr7-wire-contracts.md`

## Debugging a failure

1. `_on_err` trap prints the failing line + `ESR_E2E_RUN_ID` + tail of
   `/tmp/mock-feishu-${ESR_E2E_RUN_ID}.log`.
2. Set `ESR_E2E_RUN_ID` manually to preserve artefacts:
   `ESR_E2E_RUN_ID=debug-$$ bash tests/e2e/scenarios/01_single_user_create_and_end.sh`.
   The trap still teardowns under the same run_id at the end — comment
   out `_e2e_teardown || true` in `_on_exit` locally if you need to
   poke at `${ESRD_HOME}` or `${ESR_E2E_BARRIER_DIR}` after a failure.
3. Known-slow cold start: mock_feishu takes ~2 s, esrd ~15 s. Scripts
   have a 5 s readiness probe on the mock.
