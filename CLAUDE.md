# ESR — repo-level guidance for AI pair programming

This file is loaded as context for any Claude Code session that runs
**inside this repo**. Keep it short — the long-form docs live under
[`docs/`](docs/), and this file's job is to point at them.

> Per-role session preludes (the prompt CC sees when an *operator* spawns
> a session) live under [`roles/`](roles/), not here. Don't conflate the
> two. See [`docs/dev-guide.md`](docs/dev-guide.md) §"CC session prompt
> prelude".

## Quick orientation

- Project intro + bilingual quick start: [`README.md`](README.md)
- Module tree + PR-by-PR architecture map: [`docs/architecture.md`](docs/architecture.md)
- Authoring (handlers / adapters / patterns): [`docs/dev-guide.md`](docs/dev-guide.md)
- Authoring (agent topology, business topology, metadata): [`docs/guides/writing-an-agent-topology.md`](docs/guides/writing-an-agent-topology.md)
- **Git flow (feature → dev → main)**: [`docs/dev-flow.md`](docs/dev-flow.md)
- Field notes, indexed by topic: [`docs/notes/README.md`](docs/notes/README.md)
- Specs (every shipped feature): [`docs/superpowers/specs/`](docs/superpowers/specs/)

## Test commands (the only two you'll need 90% of the time)

| Layer | Command | Notes |
|---|---|---|
| Elixir runtime | `(cd runtime && mix test)` | Pre-existing flakes: [`docs/operations/known-flakes.md`](docs/operations/known-flakes.md) |
| cc_mcp Python bridge | `(cd adapters/cc_mcp && uv run --with pytest --with pytest-asyncio pytest)` | Never bare `python` / `pytest` |
| E2E scenario | `bash tests/e2e/scenarios/0X_*.sh` | Index in [`README.md`](README.md) §"E2E test scenarios" |

## E2E scenarios — single index

E2E coverage lives in [`tests/e2e/scenarios/`](tests/e2e/scenarios/).
The **only** discovery index is the table in [`README.md`](README.md)
§"E2E test scenarios".

> **Rule:** when you add or modify an E2E scenario, update *both* the
> README table *and* the architecture coverage table at
> [`docs/architecture.md`](docs/architecture.md) §"E2E coverage map".
> Linking from the README is required so newcomers find the scenario
> without grepping.

## Runtime layout (only what's not derivable from `git ls-files`)

- esrd WS port: `$ESRD_HOME/$ESR_INSTANCE/esrd.port` (defaults `~/.esrd` / `default`); fallback `ws://127.0.0.1:4001`
- Workspace config: `$ESRD_HOME/$ESR_INSTANCE/workspaces.yaml` — hot-reloaded via FSEvents
- cc_mcp identity env: `ESR_SESSION_ID`, `ESR_WORKSPACE`, `ESR_CHAT_IDS`, `ESR_ROLE`

## Terminology — adapter instance vs esrd environment vs esr user

Three orthogonal "principal"-shaped concepts; don't conflate them.

- **adapter instance** — a configured runtime instance of an adapter type. Created by `esr adapter add <name> --type <type>`; ASCII identifier (PR-M validates). Examples: `esr_helper`, `esr_dev_helper`.
- **esrd environment** (was: "esrd instance") — a single esrd daemon's runtime state directory. Identified by `ESRD_HOME` (`~/.esrd` for prod, `~/.esrd-dev` for dev). The env var is still `ESR_INSTANCE` for backward compat — in operator language prefer "esrd environment".
- **esr user** (PR-21a, 2026-04-29) — the canonical principal identity. Capabilities key on it; sessions are owned by it; inbound `<channel user_id="ou_…">` envelopes resolve to one via `users.yaml`. Manage via `esr user add/list/remove/bind-feishu/unbind-feishu`. Not the same as a Feishu open_id (`ou_*`) — one esr user can bind multiple feishu ids (e.g. one human registered with `esr_helper` + `esr_dev_helper` apps). Not the same as the OS user.

See [`docs/superpowers/glossary.md`](docs/superpowers/glossary.md) §"Instances & addressing" for the canonical definitions.

## Session URI shape (PR-21d)

A session is identified globally by:

```
esr://<env>@localhost/sessions/<username>/<workspace>/<session-name>
```

`<env>` lives in the URI's `org@` slot, mapping to `$ESR_INSTANCE`. tmux session name is the URI path translated `/` → `_`: `<env>_<username>_<workspace>_<session-name>`. Slash command grammar:

```
/new-session <workspace> name=<…> cwd=<…> worktree=<…>
```

`cwd` is a git worktree path (always); `worktree` is a branch name forked from `origin/main` per workspace's `root:` field. See spec [`docs/superpowers/specs/2026-04-28-session-cwd-worktree-redesign.md`](docs/superpowers/specs/2026-04-28-session-cwd-worktree-redesign.md).

## Three gotchas worth recalling

These have bitten enough times to live in the always-loaded context.
Long-form rationale lives in the linked notes.

1. **`<channel>` flat-attribute discipline** — `notifications/claude/channel`
   only forwards attributes matching `[A-Za-z0-9_]+`. Nested children
   are silently dropped. Encode list-shaped data as JSON strings
   (`reachable=` is the precedent). See
   [`docs/notes/actor-topology-routing.md`](docs/notes/actor-topology-routing.md) §8 +
   [`docs/notes/claude-code-channels-reference.md`](docs/notes/claude-code-channels-reference.md).
2. **macOS FSEvents quirk** — vim-style atomic writes to
   `workspaces.yaml` work; some editors that rename+delete trigger only
   `:stop` events and the watcher misses them. See
   [`docs/notes/actor-topology-routing.md`](docs/notes/actor-topology-routing.md) §"Watcher not reacting".
3. **`metadata:` is LLM-visible** — `workspaces.yaml`'s `metadata:`
   sub-tree is exposed verbatim via the `describe_topology` MCP tool.
   Never put secrets there; use `env:` (filtered at the response
   boundary) or `cwd:` (also filtered). See
   [`docs/guides/writing-an-agent-topology.md`](docs/guides/writing-an-agent-topology.md) §9.1.

## Conventions

- Spec-first for behaviour change: every PR with a behaviour delta links
  a `docs/superpowers/specs/<date>-<topic>.md` file. See existing specs
  for the shape.
- Field-note workflow (post-incident learnings): drop a topic-named file
  under [`docs/notes/`](docs/notes/), register it in
  [`docs/notes/README.md`](docs/notes/README.md). Keep one note per topic.
- Pre-existing flakes are tracked, not silenced — see
  [`docs/operations/known-flakes.md`](docs/operations/known-flakes.md).
- **CLI surface auto-docs**: after touching `py/src/esr/cli/**` or any
  `dispatch/2` clause in `runtime/lib/esr_web/cli_channel.ex`, run
  `bash scripts/gen-docs.sh` and commit the regenerated
  [`docs/cli-reference.md`](docs/cli-reference.md) +
  [`docs/runtime-channel-reference.md`](docs/runtime-channel-reference.md)
  in the same PR. The script walks the click tree and parses Elixir
  dispatch comments — no manual editing of those two files.

## Things to look up rather than memorise

- "How do I write a new agent / peer?" → [`docs/guides/writing-an-agent-topology.md`](docs/guides/writing-an-agent-topology.md)
- "How does cross-app reply work?" → [`docs/dev-guide.md`](docs/dev-guide.md) §"Multi-app + cross-app reply"
- "How does the LLM know which workspace it's in?" → [`docs/guides/writing-an-agent-topology.md`](docs/guides/writing-an-agent-topology.md) §九
- "Why are there two CLAUDE.md files (root + roles/)?" → [`docs/dev-guide.md`](docs/dev-guide.md) §"CC session prompt prelude"
- "What does each scenario actually exercise?" → [`README.md`](README.md) §"E2E test scenarios" + [`docs/architecture.md`](docs/architecture.md) §"E2E coverage map"
- "How do I address a thing across processes / boundaries?" → [`docs/notes/esr-uri-grammar.md`](docs/notes/esr-uri-grammar.md) + [`runtime/lib/esr/uri.ex`](runtime/lib/esr/uri.ex). **Don't invent a new identifier shape — extend the existing `esr://` URI grammar.**
- "What suffix should I use for a new module / actor / peer?" → [`docs/notes/actor-role-vocabulary.md`](docs/notes/actor-role-vocabulary.md). **Don't drift — pick the canonical role suffix (`*Adapter`, `*Proxy`, `*Process`, `*Handler`, `*Guard`, `*Registry`, `*Watcher`, `*FileLoader`, `*Dispatcher`, `*Router`, `*Supervisor`, `*Channel`, `*Socket`).** Adding a new suffix requires a documentation update first (PR-21u policy).
- "What's the durable TODO list / what's left to do?" → [`docs/futures/todo.md`](docs/futures/todo.md). Persists across sessions (in-memory `TaskCreate` is session-scoped). Update this file when deferring work or recording new known issues; CC sessions before / after this one share it as the canonical state.
