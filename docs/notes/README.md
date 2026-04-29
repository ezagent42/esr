# Developer Notes

Living index of findings surfaced during ESR development that are worth preserving but don't naturally fit in `spec/`, `plan/`, or `@moduledoc`. One file per topic; update this index when you add a note.

**Purpose**: capture empirical insights (API constraints, library gotchas, test-harness pitfalls, architectural debates) discovered during work. These are the "what we learned the hard way" artifacts.

---

## Index

| Topic | File | Summary |
|---|---|---|
| erlexec migration (2026-04-22) | [erlexec-migration.md](erlexec-migration.md) | `Esr.OSProcess` uses `:erlexec`. Native PTY + bidirectional I/O + BEAM-exit cleanup in one底座. Appendix contains the historical MuonTrap Mode 3 finding that drove the switch. |
| Feishu WS ownership stays in Python | [feishu-ws-ownership-python.md](feishu-ws-ownership-python.md) | FeishuAppAdapter doesn't own the WS — Python's `MsgBotClient` does, and forwards decoded events over Phoenix channel. Not planned to flip. |
| Capability name format mismatch | [capability-name-format-mismatch.md](capability-name-format-mismatch.md) | Spec uses `cap.*` dotted shape; `Grants.matches?/2` only parses `prefix:name/perm`. Resolve in PR-3 P3-8. |
| PR-5 perf baseline (2026-04-23) | [pr5-perf-baseline.md](pr5-perf-baseline.md) | SessionRouter dispatch latency p50/p99 — baseline for PR-6 simplify pass to compare against. |
| MCP transport orphan-session hazard (2026-04-24) | [mcp-transport-orphan-session-hazard.md](mcp-transport-orphan-session-hazard.md) | Two MCP clients registering the same logical address silently shadow each other; killing the shadowing one leaves the actor suspended. cc-openclaw precedent → ESR T11b must reject dup joins. |
| Claude Code channels reference (2026-04-24) | [claude-code-channels-reference.md](claude-code-channels-reference.md) | Channels = MCP server + `claude/channel` capability → can push notifications as `<channel>` tags. `--dangerously-load-development-channels server:<name>` required for non-allowlisted channels (ESR included). Permission relay is an opt-in capability worth considering post-T11b. |
| Tmux env propagation (2026-04-24) | [tmux-env-propagation.md](tmux-env-propagation.md) | `tmux new-session` drops non-whitelisted client-process env vars; use `-e VAR=VAL` to pass per-session env to the pane child. Was the root cause of cc_mcp KeyError at startup in scenario 01. |
| cc_mcp PubSub race on auto-create (2026-04-24) | [cc-mcp-pubsub-race.md](cc-mcp-pubsub-race.md) | CCProcess broadcasts `send_input` via pubsub before cc_mcp has joined `cli:channel/<sid>`; Phoenix drops 0-subscriber broadcasts. Fix: buffer + flush on join. |
| Testing-pyramid lessons from PR-9 T12 (2026-04-24) | [e2e-pyramid-lessons.md](e2e-pyramid-lessons.md) | 18-commit retrospective: which of the E2E-surfaced bugs belonged at which layer (E2E-only vs contract vs integration vs scenario drift), and the walking-skeleton + contract-test + "hard to unit test is a signal" practice to avoid repeating the pattern. |
| mock_feishu fidelity audit (2026-04-25) | [mock-feishu-fidelity.md](mock-feishu-fidelity.md) | Pre-PR-A precondition: 9-section gap analysis between scripts/mock_feishu.py and real Feishu / lark_oapi sourced from live-capture fixtures + cc-openclaw production adapter. Mock supports text DMs only; group chat / multi-app / non-text msg_types / token-auth / reaction events all need work. Sign-off checklist for "good enough for PR-A" included. |
| `esr://` URI grammar (2026-04-29) | [esr-uri-grammar.md](esr-uri-grammar.md) | Practical reference for the canonical addressing scheme: grammar, registered types (legacy 2-segment + path-style RESTful), every emit site with file:line, builder/parser examples in both Elixir and Python, when to add a new type. Read this before inventing any cross-process identifier. |
| Actor role vocabulary (2026-04-29) | [actor-role-vocabulary.md](actor-role-vocabulary.md) | Canonical taxonomy of role suffixes: `*Adapter`, `*Proxy`, `*Process`, `*Handler`, `*Server`, `*Router`, `*Supervisor`, `*Registry`, `*Watcher`, `*FileLoader`, `*Dispatcher`, `*Channel`, `*Socket`, `*Guard` (NEW, PR-21u), `*Buffer`. Definitions, lifecycle properties, when-to-use rules, migration plan for inline gate-shaped logic. Read before adding a new module. |
| `describe_topology` security boundary (2026-04-30) | [describe-topology-security.md](describe-topology-security.md) | The MCP tool's response builder is an explicit allowlist (`name/role/chats/neighbors_declared/metadata`). `owner`/`start_cmd`/`env`/`users.yaml` data MUST NOT leak. Procedure for adding a new exposed field + regression test pattern. |

---

## When to add a note here

- An empirical test revealed a library behaviour different from its docs
- A design choice has a subtle constraint that future engineers will hit
- A refactor discussion produced useful distinctions (not yet a decision — those go in spec)
- A test-harness pitfall caught us and we invented a workaround worth documenting

## When NOT to add a note

- **Spec'd decisions** → `docs/superpowers/specs/`
- **Implementation plans** → `docs/superpowers/plans/`
- **Per-PR progress** → `docs/superpowers/progress/`
- **Current code behaviour** → `@moduledoc` in the module itself
- **Planned future work** → `docs/futures/`

## Format for each note

1. **Context** — when / where the finding surfaced
2. **Observation** — what we saw (with evidence: code, test output, docs link)
3. **Implication** — what it changes for downstream work
4. **Mitigation** — how we work around it today
5. **Future** — when / how we might revisit

Notes are durable; update them when the underlying facts change, don't delete.
