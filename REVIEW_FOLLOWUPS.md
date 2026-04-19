# Review Follow-ups (deferred minor findings)

Final-gate code review returned **PASS-WITH-FOLLOWUPS**: 0 critical, 0 significant, 5 minor.
These are tracked here and deferred post-v0.1 per Final Gate §8 condition #5.

| # | Tag | Area | Summary | Owner |
|---|-----|------|---------|-------|
| M-A | doc-drift | PRD acceptance | A handful of PRD acceptance bullet texts mention test files with historical names that have since been consolidated — purely cosmetic, the matrix (now authoritative) is green. | docs |
| M-B | test-ergonomics | py/tests | `_submit_*` stub helpers in CLI tests raise `NotImplementedError`; once Phase 8 wires live runtime, replace with real IPC mocks. | cli |
| M-C | dead-letter | runtime | Dead-letter entries only retain the outermost envelope; for deep debugging we may want the inbound event chain. | runtime |
| M-D | telemetry | runtime | `[:esr, :handler, :retry_exhausted]` includes `actor_id` but not `handler_module` — add the latter for Grafana label parity. | runtime |
| M-E | cli-ux | py/cli | `esr scenario run` pretty output is minimal; add `--verbose` detail blocks per step + colorized PASS/FAIL. | cli |

None of the above block v0.1 acceptance — see Final Gate §8.
