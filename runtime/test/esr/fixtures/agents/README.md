# agents.yaml test fixtures

- `simple.yaml` — minimal single-agent `cc` (shipped by PR-1, P1-9).
- `multi_app.yaml` — two agents (`cc`, `cc-echo`) both referencing `${app_id}` for N=2 tests (P2-12).

## Dev stub note (P2-8)

Production esrd reads `${ESRD_HOME}/default/agents.yaml` at boot (spec §3.5). That path
lives in the user's home directory and is out-of-scope for code-only commits. Operators
should hand-place a minimal `cc` stub (mirror `simple.yaml`) into
`~/.esrd/default/agents.yaml` when setting up a fresh dev environment.
