# PubSub broadcast audit (PR-3 / P3-15)

**Date**: 2026-04-22 (PR-3 cleanup phase)
**Scope**: every `Phoenix.PubSub.broadcast` and `EsrWeb.Endpoint.broadcast`
call-site reachable from `runtime/lib/`.

Spec reference: the peer/session refactor design
(`docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §2.9)
declares that neighbor-ref `send/cast` is the data-plane primitive and
`Phoenix.PubSub.broadcast` is reserved for boundaries (adapter ↔ Python
worker, channel fan-out, telemetry, control-plane correlation).

## Allow-list (post-PR-3)

The following topic families are the only `broadcast` publishers that
survive PR-3. Any new broadcast site added to `runtime/lib/` must fall
under one of these patterns or a new row must be added here first.

| Topic family                      | Publisher(s)                                                  | Purpose                                                         |
|-----------------------------------|---------------------------------------------------------------|-----------------------------------------------------------------|
| `adapter:<name>/<instance_id>`    | `peer_server.ex`, `peers/feishu_app_adapter.ex`, `admin/commands/notify.ex` | Directive emit → Python adapter_runner subprocess (via `AdapterChannel`). |
| `handler:<module>/<worker_id>`    | `handler_router.ex`                                           | Handler RPC request → Python handler_worker.                    |
| `handler_reply:<id>`              | `esr_web/handler_channel.ex`                                  | Handler RPC response correlation (request-side `receive`).      |
| `directive_ack:<id>`              | `esr_web/adapter_channel.ex`                                  | Directive ack correlation (request-side `receive`).             |
| `cli:channel/<session_id>`        | `admin/commands/session/branch_end.ex`                        | CC-side notification push (cleanup_check_requested handshake).  |
| `session_router`                  | `peers/feishu_app_adapter.ex`                                 | FAA signals `SessionRouter` on a chat-thread miss (P3-7).       |
| `grants_changed:<principal_id>`   | `capabilities/grants.ex`                                      | Session projection refresh after capability YAML change (P3-3a).|

## Call-site inventory (verified 2026-04-22)

```
runtime/lib/esr/capabilities/grants.ex:111            Phoenix.PubSub.broadcast  grants_changed:<pid>
runtime/lib/esr/peer_server.ex:669                    EsrWeb.Endpoint.broadcast adapter:<name>/<actor_id>   (from dispatch_action emit)
runtime/lib/esr/peer_server.ex:825                    EsrWeb.Endpoint.broadcast adapter:<name>/<actor_id>   (from tool_invoke path)
runtime/lib/esr/peers/feishu_app_adapter.ex:63        Phoenix.PubSub.broadcast  session_router
runtime/lib/esr/peers/feishu_app_adapter.ex:85        EsrWeb.Endpoint.broadcast adapter:feishu/<app_id>
runtime/lib/esr/handler_router.ex:51                  EsrWeb.Endpoint.broadcast handler:<module>/<worker>
runtime/lib/esr/admin/commands/notify.ex:41           Phoenix.PubSub.broadcast  adapter:feishu/<app_id>
runtime/lib/esr_web/handler_channel.ex:59             Phoenix.PubSub.broadcast  handler_reply:<id>
runtime/lib/esr_web/adapter_channel.ex:95             Phoenix.PubSub.broadcast  directive_ack:<id>
runtime/lib/esr/admin/commands/session/branch_end.ex:243  Phoenix.PubSub.broadcast  cli:channel/<session_id>
```

All ten sites map cleanly onto the allow-list; zero violations.

## Removed in PR-3 (history)

- `routing/slash_handler.ex:287,309` — legacy `feishu_reply` + `msg_received`
  broadcasts. Deleted in **P3-14** with the `Esr.Routing.SlashHandler`
  module; slash-parsing is now a per-Session peer (`Esr.Peers.SlashHandler`)
  that pushes results back via the peer `handle_downstream` chain rather
  than a broadcast.
- `topology/instantiator.ex:254,288` — `directive_ack:<id>` fan-out used
  by the old artifact `init_directive` loop. Deleted in **P3-13** with
  the `Esr.Topology` module; the surviving `directive_ack:<id>`
  publisher is `EsrWeb.AdapterChannel`, consumed by `PeerServer`'s
  `Emit` waiter.

## Banned patterns (enforcement note)

Reviewers and future authors: **do not** add new broadcast call-sites
that match any of the following shapes:

1. **Data-plane forwarding via broadcast.** If peer A needs to deliver
   a message to peer B inside the same session, use a neighbor-ref
   `send/cast` captured at construction time. Broadcasts for data-plane
   forwarding re-introduce the spec §2.9 failure mode (slow subscribers
   back-pressure the publisher; subscription leaks accumulate silently).

2. **Cross-session "workspace" or "agent" topics.** Sessions are
   supposed to be isolated per spec §3.5 / Track-D. If a cross-session
   signal is genuinely needed, add a control-plane hop via
   `SessionRouter` (which owns the cross-session view) rather than a
   public topic that any peer can subscribe to.

3. **Per-actor `actor:<id>` topics.** The `Esr.PeerRegistry` already
   gives every actor a callable `send/cast` target; a broadcast topic
   adds an extra pub/sub layer with no correlation benefit.

## Risk notes

- The `adapter:<name>/<instance_id>` family has three publishers
  (`peer_server` legacy emit path, `feishu_app_adapter` outbound,
  `admin/commands/notify`). Per spec §8.2, PR-4b will migrate the
  `peer_server` publisher into the adapter_runner split; after that
  only `feishu_app_adapter` + `admin/commands/notify` remain. Track
  this as a cleanup debt item on the PR-4b plan, not a PR-3 blocker.

- `session_router` is a single-subscriber topic (only `Esr.SessionRouter`
  subscribes to it). A `send(Esr.SessionRouter, ...)` with a
  `Process.whereis` lookup would work just as well. Kept as broadcast
  for resilience during SessionRouter restarts (a missed message during
  that window is preferable to a crash in FAA's `handle_upstream`).
