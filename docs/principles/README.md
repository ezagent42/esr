# ESR Development Principles

Development-process rules of the road for the ESR project. Each
principle lives in its own file; this README is the index. Updated
as the team accumulates hard-won defaults.

Target audience: any engineer (human or agentic) working on this
codebase. Read the relevant principle before starting a task where
the tradeoff applies; when in doubt, defer to the principle rather
than optimizing locally.

## Index

| Principle | File | One-line |
|---|---|---|
| E2E faces production topology | [01-e2e-faces-production.md](01-e2e-faces-production.md) | Fix the production flow, not the test harness |
| E2E failure earns a unit test | [02-e2e-failure-earns-unit-test.md](02-e2e-failure-earns-unit-test.md) | Every distinct e2e bug gets a fast regression test |
| Production usability is the selection criterion | [03-production-usability-criterion.md](03-production-usability-criterion.md) | When choosing between approaches, pick the one closer to real production |

## Adding a principle

1. Write `NN-<short-name>.md` with a concise statement, rationale, and a concrete example.
2. Add a row to the Index table above.
3. Prefer principles that describe **what we've learned the hard way**, not aspirational best-practices copied from elsewhere. Each principle should be traceable to a specific decision or incident.
