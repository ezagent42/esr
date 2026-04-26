# Lane A RCA — why dual-lane auth happened, how to prevent it next time

Captured 2026-04-26 alongside the Lane A removal PR.

## TL;DR

Lane A (Python adapter-side gate) shipped with PR-9 as
**defense-in-depth** for an auth check that already lived in Lane B
(Elixir runtime). The two lanes ran the same `Capabilities.has?`
against the same yaml and stayed in sync as long as both were
running. They diverged when:

1. Lane B added the same telemetry / observability path Lane A had
   been there to provide → Lane A's "save a runtime hop" justification
   evaporated.
2. The yaml-sync burden grew (PR-A's per-instance + per-app
   capabilities became dual-write to `default/` for Lane A and
   `<instance>/` for Lane B).
3. Nobody had license to delete a working safety net, so it stayed.

End state: a 4-state truth table with two latent-bug states
(allow/deny + deny/allow), forced dual-write yaml, and `permissions:
[]` `handler_hello` workarounds in test setups that were tracking
the gap between the lanes.

## How the dual-lane state arose

Read git history at the points where Lane A entered:

**PR-9 era (~Feb 2026)** — first cap subsystem. The architecture
question on the table was "where do `msg.send` checks fire?"
Two reasonable answers:

- **Adapter-side (Python)**: cheap to implement (per-platform), runs
  before any data crosses the IPC boundary, easy to short-circuit
  unauthorized inbound and avoid a runtime hop. Costs:
  per-platform-implementation, dual yaml read.
- **Runtime-side (Elixir)**: single source of truth, all auth in
  one process, no need to re-implement per platform. Costs:
  unauthorized inbound costs an IPC hop before being dropped.

We chose **both**, because:

1. The runtime gate was non-negotiable (admin/test/route paths bypass
   the adapter, so Lane B has to be there).
2. Adapter-side felt like "easy bonus protection" — a half-day to
   implement and a clear short-circuit gain.

Choosing both was not, on its own, the bug. The bug was that no
one wrote down the **conditions under which the adapter gate becomes
redundant**. Specifically:

- "Once Lane B emits structured deny telemetry that operators can
  alert on" — the runtime hop cost stops mattering.
- "Once Lane B sends user-facing deny feedback (the deny DM)" —
  Lane A's UX role evaporates.

Both happened during PR-9 + post-PR-9 incremental work. Without a
sunset condition recorded, no one took down Lane A.

**PR-A era (Apr 2026)** — multi-app + per-instance capabilities.
This was where the dual-lane pain crystallised:

- Lane A read `${ESRD_HOME}/default/capabilities.yaml` (a path
  hardcoded in the Python adapter).
- Lane B read `${ESRD_HOME}/<instance>/capabilities.yaml` (per
  PR-A's instance-scoped runtime).
- The e2e harness (`common.sh:seed_capabilities`) had to write the
  same content to BOTH paths. Operators outside e2e didn't have
  this dual-write encoded anywhere — so live deployments quietly
  ran with mismatched yamls when admins edited only one.
- A separate PR-9-era TODO had been blocked on "`permissions: []`
  in `handler_hello` makes the FileLoader reject any non-wildcard
  cap." That TODO was load-bearing on Lane A's existence — once
  Lane A is gone, the TODO closes itself because Lane B uses the
  runtime's permissions registry which `handler_hello` doesn't
  filter.

Despite both lanes doing the same `Capabilities.has?` lookup against
the same yaml shape, they diverged in 4 states:

| Lane A | Lane B | What user sees | What runtime knows |
|---|---|---|---|
| allow | allow | Message processed, no DM | Auth event observed normally |
| deny | deny | Deny DM sent | Lane B telemetry fires |
| **allow** | **deny** | Inbound vanished, no DM | Bug: "I sent it but bot ignored me" |
| **deny** | **allow** | Deny DM sent | Bug: runtime had nothing to deny |

The two divergent rows became latent-bug states. They were rare
because operators edited both yaml paths in lockstep when prompted by
the e2e helper, but production operators didn't have the helper.

## Why we didn't catch it earlier

1. **No sunset condition was recorded for Lane A.** "Defense in depth"
   is a stable label; "redundant after Lane B's telemetry lands" is
   an action item. We had the first, not the second.
2. **The dual-lane was visible only in the e2e helper.** Production
   operators editing one file and not the other never saw a unified
   diagnostic. The dual-write was an implementation artifact, not a
   documented contract.
3. **Tests masked the gap.** The `allow_all_capabilities` fixture in
   `conftest.py` granted `*` to every test principal and wrote it to
   the path Lane A read; tests passed because Lane A was permissive
   by construction in the test environment. Real audits of the
   "what happens when Lane A and Lane B disagree" path were rare.
4. **No quantification of the cost.** "Save a runtime hop" sounds
   cheap; nobody measured how many denies actually fired in
   production. The answer was "near-zero, because most users
   chat-membership-gate happens at Feishu before the inbound even
   reaches us." Lane A was guarding a near-empty case.

## Recommendations for next time

These are checks to run before adding ANY second-layer gate that
duplicates an existing first-layer gate:

### Before adding the layer

1. **Write the sunset condition.** Inside the same PR introducing
   Layer-2, add a one-line comment: "Layer-2 should be removed when
   `<concrete observable>` exists." Concrete observables: a
   telemetry event, a CLI command, a doc, an audit trail.
2. **Quantify the win.** Estimate: "Layer-2 drops X% of inbound
   without a runtime hop, measured by Y telemetry over Z window."
   If the answer can't be cited at design time, the win is
   speculative — push back.
3. **Make the synced state observable.** If Layer-1 and Layer-2 both
   read configuration, the system MUST emit a startup log line saying
   "Layer-1 read N grants from path-A; Layer-2 read M grants from
   path-B; N==M." Without it, divergence is invisible until users
   complain.

### After both layers exist

4. **Audit the truth-table quarterly.** With two layers there's a
   2×2 truth table. The off-diagonal cells (allow/deny + deny/allow)
   are bugs by definition. Write a test that asserts the cells are
   unreachable in steady state. If you can't write the test, you've
   accepted unbounded risk.
5. **Sunset triggers fire automatically.** When the sunset condition
   from #1 lands, Layer-2 should be removed in the same PR or the
   adjacent one. "I'll get to it later" doesn't ship; "this PR is
   conditional on opening the removal PR by date X" does.

### Process-level

6. **Spec/PR templates ask "is this a duplicate gate?"** Same way
   commit messages have a "fixes #" line. If the answer is "yes",
   the PR description must include the sunset condition AND the
   audit-test path.

## What this PR demonstrates

Lane A was a clean removal because the post-PR-9 telemetry happened
to give us a full sunset (`[:esr, :capabilities, :denied]` covers
every observability question Lane A's deny path used to answer; the
deny-DM relocation to Lane B's FAA dispatch covers the user-feedback
question). The cleanup was achievable because *only* the deny-DM
rendering had moved between the two lanes — the gate logic was
already identical. If the lanes had subtly diverged in policy
(different cap shapes, different cache TTLs, different fallback
behaviour) the cleanup would have been a multi-PR dance instead of
the 8-task one this turned into.

The recommendation in §"Before adding the layer" — write the sunset
when you write the layer — is the cheapest available form of this
prevention. It costs one comment in one PR.

## See also

- Migration note: `docs/notes/auth-lane-a-removal.md` (operator-facing)
- Spec (approved v1.4): `docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md`
- Lane B inbound gate: `runtime/lib/esr/peer_server.ex:236-274`
- FAA deny-DM dispatch: `runtime/lib/esr/peers/feishu_app_adapter.ex` (search `@deny_dm_text`)
