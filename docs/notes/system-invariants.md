# ESR system invariants

These five cross-supervisor effect-level invariants hold for any
session in good standing. They are codified in
`runtime/test/esr/system/invariants_test.exs` against the
`Esr.Test.ChaosScenarios` DSL (PR-3 Task 3.8).

Each invariant is named with an `I<n>` tag so a violation surfaces as
a single-line failure in CI output.

| ID | Statement | Verification |
|---|---|---|
| **I1** | Every chat inbound reaching FAA produces a chat-visible reply or chat-visible error within 5 seconds | `invariant_test "I1: …"` in `invariants_test.exs` (chaos_inject + send_test_inbound + assert_chat_reply_within) |
| **I2** | Every alive entry in `:esr_session_chat_routing` ETS points at a session whose FCP pid is alive in `Esr.ActorQuery`, OR the routing slot has already been detached | `eventually/3` polling pass after chaos_inject |
| **I3** | A `session_dir` exists on disk iff its supervisor tree has an alive root (no orphan dirs, no orphan trees) | Observer-based: kill the supervisor, assert dir is gone within a deadline. Skipped in routing-only ChaosScenarios fixture; requires the integration branch. |
| **I4** | Agent process death (any cause, incl. supervisor giveup) produces a chat-visible lifecycle reply within 5 seconds | LifecycleObserver (PR-3 Task 3.7) emits via FAA.reply_chat_error/4 on monitored-supervisor DOWN. |
| **I5** | No routing-layer code uses the `other -> Logger.warning + drop` catch-all pattern | CI grep gate over the FAA + Router + SlashHandler files. |

## Source

Spec: `docs/superpowers/specs/2026-05-11-default-agent-and-agent-driven-flow-design.md` §4.7.
Plan: `docs/superpowers/plans/2026-05-11-default-agent-and-agent-driven-flow-plan.md` §PR-3 Task 3.9.

## Operational note

I1-I4 are unit/integration-level — a failure surfaces in `mix test`.
I5 is a static gate — it fails CI before any test runs.

When I3/I4 require infrastructure that doesn't exist in a test
fixture (`session_dir` on-disk write hook, full pipeline boot), the
invariant test stubs the missing parts and falls back to the
routing-layer assertion. The integration suite is the canonical
verification site for I3/I4.

## Updating the invariants

Adding a new invariant:

1. Append a row to the table above with a stable `I<n>` identifier.
2. Write a corresponding `invariant_test/2` in `invariants_test.exs`
   (or a CI gate for static invariants).
3. Update the spec + plan if the invariant has architectural
   implications.

Never remove an invariant — they're the system's load-bearing
contracts. Soften the statement if the system has legitimately
evolved past a strict claim, but keep the historical row.
