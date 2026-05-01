# Issue 02 — Decouple cc_mcp from claude / tmux lifecycle

Open. Brainstorm pending 2026-05-01.

## TLDR

- **Problem:** `cc_mcp` is a Python MCP server that claude spawns as a stdio subprocess. Its lifecycle is parented by claude, which is parented by tmux. When tmux dies (manual `tmux kill-server`, host reboot residue, claude crash), claude dies, cc_mcp dies, **its `cli:channel/<sid>` PubSub subscription dies** — and any subsequent inbound silently drops because no subscriber exists. Even if FCP / cc_process are still alive in BEAM, the message gets lost. PR-21ψ/ω' rewire-on-restart helps the BEAM-side neighbor pid hygiene but doesn't recover the dead cc_mcp.
- **Decision:** TBD — brainstorming.
- **Why:** TBD.
- **Where it landed:** TBD.

## Context

Today's process tree per session:

```
peers DynamicSupervisor (BEAM)
  ├─ FCP            (Stateful peer, BEAM-supervised)
  ├─ cc_process     (Stateful peer, BEAM-supervised)
  └─ TmuxProcess    (OSProcess peer, BEAM-supervised via erlexec)
       └─ /bin/sh -c "scripts/esr-cc.sh"
            └─ exec claude --mcp-config .mcp.json
                 └─ claude reads .mcp.json, spawns:
                      cc_mcp = Python subprocess (parent = claude, stdio MCP)
```

cc_mcp's connections (subscribed at process start):
- WebSocket to esrd at `cli:channel/<session_id>` topic — receives notification envelopes
- WebSocket to esrd at admin / handler channels (depending on the role)

## What goes wrong on tmux death

```
tmux server dies
  → claude dies (lost its terminal)
  → cc_mcp dies (stdio closed)
  → cc_mcp's cli:channel/<sid> subscription is gone
                ↓
TmuxProcess.on_terminate fires (BEAM-side)
  → restart strategy decides
                ↓
Pre-PR-21ω'': normal exit (status 0) → :transient → NO restart
              cc_process / FCP / SessionRegistry stay alive
              Next inbound: FAA → FCP → cc_process → broadcast cli:channel/<sid>
                                                     ↓ NO subscribers, message dropped
              Operator sees silence.

Post-PR-21ω'': ANY exit → restart → new tmux + new claude + new cc_mcp
              cc_mcp connects to cli:channel/<sid>, subscribes again
              PR-21ω' rewire patches new tmux pid into FCP / cc_process
              Operator sees claude resume — but mid-conversation context lost
              (claude's `--resume <prior-session-id>` mechanism is half-built;
              session-ids.yaml write side never landed).
```

PR-21ω'' (this PR's stopgap) makes the system self-heal at the cost of losing the active conversation. **Issue 02 asks: can we do better — keep cc_mcp alive across claude/tmux restarts?**

## Why cc_mcp is parented by claude today

claude's MCP support uses **stdio** transport when configured via `command + args`. Stdio means claude opens a pipe to the subprocess; both must be parent-child. This was the simplest setup — claude reads `.mcp.json`, spawns the listed servers, talks via stdin/stdout.

But MCP also supports **HTTP** transport: `{type: "http", url: "..."}`. With HTTP, claude POSTs MCP requests to a URL. The MCP server is just an HTTP server, lifecycle independent of claude.

## Proposed re-architecture

```
peers DynamicSupervisor
  ├─ FCP / cc_process / TmuxProcess        (existing)
  └─ NEW: CCMcpProcess                     (BEAM-supervised OSProcess)
        └─ Python: `python -m esr_cc_mcp.channel_http`
           bound to ephemeral port (e.g. 127.0.0.1:54321)
           lifecycle independent of tmux/claude
           connects to cli:channel/<sid> at startup, subscription lives
           as long as CCMcpProcess does

esr-cc.sh writes .mcp.json with:
  { mcpServers: { "esr-channel": { type: "http", url: "http://127.0.0.1:<port>" } } }
```

**Lifecycle:**
- Session created → BEAM spawns FCP / cc_process / TmuxProcess + **CCMcpProcess** (parallel)
- CCMcpProcess binds port, registers in `Esr.PeerRegistry` under `"cc_mcp_port:<sid>"`
- TmuxProcess.os_env reads the port from the registry, exports `ESR_CC_MCP_PORT=<port>`
- esr-cc.sh interpolates port into `.mcp.json` before exec claude
- claude → MCP HTTP requests to cc_mcp via `127.0.0.1:<port>`
- tmux dies → claude dies → CCMcpProcess survives → subscription preserved
- TmuxProcess restart (per PR-21ω'') → new claude → reconnects via HTTP to existing CCMcpProcess → sees queued notifications
- CCMcpProcess crash → BEAM supervisor restarts → new port → re-broadcasts to claude (or claude reconnects)

## Multi-tenancy: 1-cc_mcp-per-session vs 1-shared

**1:1 (recommended):** Each CC session has its own CCMcpProcess. Process boundary = tenant boundary. ESR_SESSION_ID env is per-process. Failure of one cc_mcp doesn't affect others. Costs ~50–100 MB extra Python memory per active session — acceptable.

**1:N shared:** One cc_mcp serves all sessions; routes by session_id in HTTP path / header. Cheaper memory, but multiplexing logic adds complexity, single point of failure. Not recommended.

## Estimate

- **Python (cc_mcp)**: add HTTP transport entrypoint `esr_cc_mcp.channel_http`. Port binding, routing, MCP-over-HTTP framing. ~50–100 LOC + tests.
- **Elixir**: new `Esr.Peers.CCMcpProcess` peer module (OSProcess-backed). Spawn `uv run python -m esr_cc_mcp.channel_http`, capture port from stdout (cc_mcp prints `bound to port=<N>` on start), register in PeerRegistry. ~150 LOC + tests.
- **agents.yaml**: add `cc_mcp_process` to the `cc` agent's `pipeline.inbound`.
- **esr-cc.sh**: read `ESR_CC_MCP_PORT` env, interpolate into `.mcp.json`. ~5 LOC.
- **Tests**: kill tmux, verify cc_mcp survives, verify next inbound reaches new claude. Integration test ~50 LOC.

**Total: ~300 LOC + design discussion.**

## Open questions

1. How does CCMcpProcess publish its bound port back to TmuxProcess (which writes the .mcp.json)? Options: (a) cc_mcp prints port on stdout, BEAM peer parses and stores; (b) CCMcpProcess takes a fixed port from session_id hash; (c) BEAM allocates port via inet, passes to cc_mcp as env var.
2. What happens to cc_mcp's WebSocket subscription if esrd itself restarts? cc_mcp would need reconnect logic (probably already has — verify).
3. Does claude's HTTP MCP transport support all the features stdio does (long polling? streaming?)? Need to verify.
4. cc_mcp is currently auth-less (trusts stdio parent = claude). Switching to HTTP needs a token / shared secret for the localhost binding.
5. session_ids.yaml write side (write claude's session_id back to disk for `--resume`) is the orthogonal "context preservation across claude restart" issue — separate from cc_mcp lifecycle but related to "what does the operator see after restart". Should this be solved in the same PR?

## References

- Current cc_mcp: `py/src/esr_cc_mcp/channel.py`
- claude MCP transport docs: `--mcp-config` accepts both `command/args` (stdio) and `type: "http"` shapes
- esr-cc.sh: `scripts/esr-cc.sh`
- Related: docs/issues/closed-01-tmux-vs-erlexec-pty.md (decided keep tmux for operator multi-attach)
- Related: PR-21ψ rewire-on-restart, PR-21ω rollback, PR-21ω' deadlock-safe re-impl, PR-21ω'' on_os_exit always-restart (stopgap until issue 02 lands)
