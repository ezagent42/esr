# 01. E2E tests face production topology, not test-harness shortcuts

## Statement

E2E tests must exercise the same code path a production user would
traverse. When an e2e scenario fails because of a shortcut, fix the
production flow rather than the test harness.

## Why

ESR's goal is to run `esrd` in production. A test that goes green by
injecting state a real user couldn't inject — or by skipping a step
a real flow requires — proves nothing about production. Worse, it
hides the real work and lets broken production code ship.

The "shortcut to green" is the most common failure mode when an e2e
fails; it deserves active resistance.

## How to apply

- When an e2e step fails, ask: **"does a production user hit this?"** If yes, fix production code.
- If the answer is genuinely "no" (test-only plumbing like isolated tmux sockets, or synthetic mock hooks that won't ship), fix the harness — but be suspicious. The default answer should lean "yes".
- When two approaches are available ("quick mock" vs "real flow"), prefer the real flow unless there's tight-deadline justification + explicit approval.

## Concrete example (PR-7 `make e2e`, 2026-04-23)

Scenario 01 step 1 used `esr cmd run "/new-session ..."` — a CLI the
orchestrator invented that doesn't exist. The tempting "fix" was to
remove the step or fake the result. The correct fix was to use the
real admin CLI (`esr admin submit session_new --arg agent=... --arg
dir=...`) AND to plan a follow-up that routes `/new-session` through
the actual Feishu slash path (the production flow a user would use
when DM'ing the bot).

Six underlying infrastructure bugs surfaced in the same session:
Makefile portability (macOS), ESR_INSTANCE env propagation to the
BEAM, capability seeding for ou_admin, Endpoint ETS race in admin
orphan recovery, mock_feishu teardown port leak, agents.yaml
auto-load. All six were real production gaps, fixed in production
code, not worked around in bash.

## Cross-refs

- Memory: `feedback_e2e_faces_production.md`
