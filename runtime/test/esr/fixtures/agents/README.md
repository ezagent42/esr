# Agent test fixtures

Phase 6 (2026-05-10) dissolved the production `agents.yaml` source —
agent kinds are now declared in each plugin's manifest `agent_kinds:`
block and registered into `Esr.Plugin.AgentKindRegistry` at boot.

These yaml files are retained as **test fixtures only** — they are not
loaded by production esrd boot, and there is no longer any
`Esr.Entity.Agent.Registry.load_agents/1` to consume them. Tests that
need a canonical `cc` agent_def shape parse them via
`Esr.TestSupport.AgentDefFixture.cc_agent_def/1`, which returns the
same map shape `Esr.Session.AgentSpawner` consumes.

- `simple.yaml` — single-agent `cc` fixture with the **full CC chain**
  (`feishu_chat_proxy → cc_proxy → cc_process → pty_process`) as of
  P3-6. Used by direct-invocation Router/AgentSpawner tests
  (e.g. `runtime/test/esr/integration/cc_e2e_test.exs`).
- `multi_app.yaml` — two-agent fixture (`cc`, `cc-echo`) for N=2
  routing tests; the `cc-echo` agent is intentionally a minimal
  feishu-only echo pipeline (no CC peers) to keep N=2 tests focused
  on per-session isolation. Note: post-Phase-6, callers that don't
  exercise agent_def threading typically drop the load entirely
  (`n2_sessions_test.exs` and `perf/session_router_dispatch_latency_test.exs`
  did exactly that).

## Production world (post-Phase-6)

Operators who want a CC session simply enable the `claude_code`
plugin (default in fresh esrd installs) — the `claude_code.cc`
agent_kind is auto-registered at boot from
`runtime/lib/esr/plugins/claude_code/manifest.yaml`'s `agent_kinds:`
block. There is no longer any `~/.esrd/<inst>/agents.yaml` to
hand-place.

The pre-Phase-6 production stub block (formerly listed here as a
copy-paste for fresh installs) is gone — operators need do nothing
beyond the plugin registration that the in-tree manifest already
ships.
