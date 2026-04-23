# PR-5 Performance Baseline — SessionRouter Dispatch Latency

**Date**: 2026-04-23
**Hardware**: Darwin H2OSLabsdeMac-Studio.local 25.2.0 Darwin Kernel Version 25.2.0: Tue Nov 18 21:09:41 PST 2025; root:xnu-12377.61.12~1/RELEASE_ARM64_T6031 arm64
**Build**: post-PR-5 tree at merge commit TBD (fill in after P5-12).

## Methodology

Synthetic smoke at `runtime/test/esr/perf/session_router_dispatch_latency_test.exs`.
Loops 1000 iterations of:

1. Time T0.
2. `send(feishu_app_adapter_pid, {:inbound_event, envelope})` — the real
   entry point for webhook traffic; `SessionRouter` itself is
   control-plane and does not dispatch `:inbound_event`. See the
   moduledoc in the test file for the bootstrap adjustment rationale.
3. Wait for a stubbed peer (a plain pid registered as the session's
   `feishu_chat_proxy` + `tmux_process` neighbors) to receive the
   relayed `{:feishu_inbound, envelope}` frame.
4. Time T1; sample = T1 - T0 in microseconds.

One un-measured warm-up iteration runs before the timed loop so lazy
registry-ETS / mailbox-warmup costs don't poison sample 0.

## Numbers

| Percentile | Latency (µs) |
|---|---|
| p50 | 2 |
| p99 | 7 |

Run-to-run variance on the measurement hardware: p50 stable at 2 µs,
p99 observed in the 4–7 µs range across four back-to-back runs.
Numbers are also written to
`$TMPDIR/esr-pr5-perf-baseline.tsv` by the smoke itself for PR-6 to
pick up without re-running.

## How to reproduce

```bash
cd runtime && mix test test/esr/perf/session_router_dispatch_latency_test.exs --only perf
```

## PR-6 comparison policy

PR-6's simplify pass touches hot paths in the control plane. Rerun
the smoke after PR-6 merges; fail the simplify pass if p99 > baseline
p99 × 1.20.
