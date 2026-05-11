# ESR full user journey

The complete operator-facing journey, broken into sub-flows. Each
sub-flow has its own fenced guide that doubles as the e2e replay
source. CI runs `scripts/replay-guide.sh` against every fenced
guide on every PR.

**Vocabulary:** see [`CONTEXT.md`](../../CONTEXT.md) for the
journey/flow/guide/scenario terms.

| Sub-flow | What it covers | Guide | E2E scenario |
|---|---|---|---|
| Bootstrap | Fresh esrd → first user → register adapter → bind feishu → workspace + session + agent → first CC reply | [flow-bootstrap.md](flow-bootstrap.md) | [19_session_first_default.sh](../../tests/e2e/scenarios/19_session_first_default.sh) |
| SessionTemplate (Feishu test) | Operator end-to-end test of SessionTemplate + Channel migration | [flow-sessiontemplate-feishu-test.md](flow-sessiontemplate-feishu-test.md) | (none yet — Phase 3 organic) |

Rows for further sub-flows (multi-session, PTY attach, plugin lifecycle,
bundle install, ...) are added by feature PRs as they ship — see the
anti-drift rule in [spec §3.3](../superpowers/specs/2026-05-10-guide-driven-e2e.md#33-docsguidesfull-user-journeymd--the-gold-standard-index).
