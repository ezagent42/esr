# MCP transport orphan-session hazard

**Context**: Surfaced 2026-04-24 while running the ESR peer/session refactor
work (T11a → T11b handover). Issue lived in **cc-openclaw's** channel-server,
not in ESR's runtime — but the underlying pattern (multiple MCP clients
registering the same logical address) could re-surface in ESR's own
`EsrWeb.ChannelChannel` (cli:channel/<session_id> topic) during T11b, so the
debugging recipe is worth preserving.

## Observation

cc-openclaw's channel-server binds one CC-side WebSocket to a logical address
`cc:<user>.<session>` (e.g. `cc:linyilun.root`). When two independent `claude`
processes both start with the same MCP config, **both register under the same
address**:

```
16:00:37  connection open
16:00:37  connection open            ← two concurrent WS connects
16:00:37  Attached transport to existing CC actor: cc:linyilun.root
16:00:37  Wired cc:linyilun.root → feishu:...
16:00:37  Attached transport to existing CC actor: cc:linyilun.root   ← double
16:00:37  Wired cc:linyilun.root → feishu:...                         ← double
```

The server's "attach transport" is last-writer-wins. The second registration
silently shadowed the first — the *visible* client (the one the human thought
they were typing into) was no longer the transport target.

When the shadowing client was killed:

```
18:40:43  Detached transport on disconnect: cc:linyilun.root
18:40:43  Actor cc:linyilun.root loop cancelled
18:40:43  Actor cc:linyilun.root loop exited (state=suspended)
```

Server detached the transport but **did not re-attach to the other, still-live
client**. Subsequent Feishu inbound events routed successfully all the way to
`cc:linyilun.root`'s actor mailbox, then hit:

```
18:40:50  WARNING  send: actor cc:linyilun.root has no running loop task
                   (state=suspended, task=missing)
```

Messages silently dropped on the floor. The surviving `claude`'s MCP client's
TCP connection stayed alive (PING/PONG continued) so it never knew to
re-register.

## Implication

The failure mode is: **user sees my outbound messages fine, but everything they
send vanishes**, with no error surface anywhere — the server log's WARNING is
easily missed under the `processor not found` noise from Lark's info events.

For ESR's T11b, which ports the same MCP bridge pattern through
`EsrWeb.ChannelChannel`, the symmetric hazard would be two `cc_mcp` subprocesses
(or one subprocess + an orphan from a previous incarnation) both joining the
same `cli:channel/<session_id>` topic.

## Mitigation (both for cc-openclaw's lesson and for ESR's T11b design)

**Detection**:
- Grep for `no running loop task` / `state=suspended` warnings on the server
  side. These are the canary.
- Look for back-to-back `Attached transport to existing CC actor: <same-addr>`
  entries at the same timestamp. That's the double-register smoking gun.

**For debugging now (cc-openclaw)**:
- `launchctl kickstart -k ai.openclaw.channel-server` force-drops all WS
  connections. Every surviving MCP client auto-reconnects cleanly and the
  registry is re-built from scratch — fastest way to clear the suspended-actor
  state without killing the CC session.

**For ESR T11b (what to design in)**:
- `EsrWeb.ChannelChannel.join/3` should **reject** a second join on the same
  `cli:channel/<session_id>` topic rather than silently shadowing. Phoenix
  channels don't auto-enforce uniqueness; explicit check against
  `Esr.SessionSocketRegistry` for an existing binding + reject with
  `{:error, %{reason: "already_joined"}}` closes the hazard.
- On transport detach, the session actor should stay *active*, not suspend.
  Suspension is a footgun — the unambiguous state after a client leaves is
  "wait for a fresh join", which is cleaner as an always-active actor that
  simply has no transport to push to (enqueue + redeliver on next join).

## Pointers

- Root-cause trace from the live incident (2026-04-24 16:00-18:43):
  `/Users/h2oslabs/.openclaw/logs/channel-server.err.log`
- cc-openclaw channel.py reference implementation:
  `/Users/h2oslabs/cc-openclaw/channel_server/adapters/cc/channel.py`
  and `adapter.py` (both referenced by this design's T11b §2).
- ESR-side boundary to harden: `runtime/lib/esr_web/channel_channel.ex`
  `join/3` + `EsrWeb.SessionSocketRegistry` two-phase check.
