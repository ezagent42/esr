# Future: Cross-Workspace Messaging Handler

Status: **not started** — future implementation target.
Author: brainstorming session with user (linyilun), 2026-04-20.
Relates to: `docs/superpowers/specs/2026-04-20-esr-capabilities-design.md`
(permission model ready); `handlers/feishu_app/` and
`handlers/feishu_thread/` (existing handler patterns to follow).

## Why this document exists

During the capabilities brainstorm, we surfaced this concrete user
scenario:

> (3a) User A can send a message to user B via App1, notifying via App2.
> (3b) After App2 notifies, user B only has reply permission, not
>      initiate.

Scenario 3b is fully solvable **today** via the capability model alone —
grant B `workspace:app2/msg.send` without `workspace:app2/session.create`,
and B can continue existing threads but not start new ones.

Scenario 3a needs *new application code*, not a new permission mechanism.
The permission model already supports any actor-to-actor routing (see the
capabilities spec §6.5 on how `principal_id` flows through the stack); what
ESR is missing is:

1. A **tool primitive** that lets a handler target an arbitrary
   `(workspace, chat_id or open_id)` when sending a message — not just
   "reply in the chat this message came from".
2. A **handler** that processes a cross-workspace-send command and emits
   that tool.

This document describes what that work would entail so it's actionable when
the time comes.

## The gap in concrete terms

### What exists today

- `feishu_app_proxy` — receives Feishu `msg_received` events for one app,
  routes them to the current thread's `feishu_thread_proxy`, or handles
  `/new-thread` / `/session:new` meta-commands.
- `feishu_thread_proxy` — one per active CC thread; notifies the CC
  session of inbound messages; sends CC outbound as Feishu replies.
- The `reply` / `react` / `send_file` / `_echo` MCP tools — all implicitly
  targeted to "the chat that the current session is bound to".

### What's missing

A handler that does, roughly:

> When a user issues `/send-via-app2 <target_open_id> <text>` in App1's
> chat, emit a directive that targets App2's adapter and sends a DM to
> the specified target user.

And a tool primitive that the handler can call — something like:

```
tool: "send_to_user"
args:
  workspace_name: "app2-prod"        # which workspace (= which adapter instance)
  receive_id: "ou_target_user"       # Feishu open_id
  receive_id_type: "open_id"         # or "chat_id"
  text: "notification body"
```

## Sketch of the work

### Tool primitive

Add `send_to_user` (or a better name) alongside the existing four tools
in `runtime/lib/esr/peer_server.ex:680-740`. Its `build_emit_for_tool`
implementation:

1. Resolves the target adapter by `workspace_name` via
   `Esr.Workspaces.Registry` (pick an `app_id` that's part of the
   workspace, find the matching adapter instance).
2. Constructs an emit envelope targeted at that adapter, carrying the
   `receive_id` / `receive_id_type` / `text`.
3. The target adapter's `on_directive` handler translates this into an
   `im.v1.message.create` call against Feishu.

Declare it as a permission in `Esr.PeerServer.permissions/0`:
`"send_to_user"`. The CAP-2 registry will auto-pick it up.

### Handler

A new Python handler — call it `cross_notify_proxy` or similar, living at
`handlers/cross_notify/`. The handler:

1. Is bound to App1's workspace (or configured per deployment to listen
   in specific chats).
2. Parses incoming messages looking for `/send-via-app2` (or whatever
   verb / grammar makes sense). Could also be triggered by natural
   language if the handler is LLM-backed — pattern-matched CLI is simpler
   for v1.
3. Extracts the target open_id and message text.
4. Emits a `tool_invoke` directive with `tool: "send_to_user"` and args
   pointing at App2's workspace + the target user.

### Permissions needed

For user A to successfully run this flow, A must hold:

```yaml
principals:
  - id: ou_user_a
    capabilities:
      # Lane A: A can send messages in App1
      - "workspace:app1-prod/msg.send"
      # Lane B: A's message triggers the cross-notify handler
      - "workspace:app1-prod/session.switch"
      # Lane B: the handler on A's behalf calls send_to_user targeting App2
      - "workspace:app2-prod/send_to_user"
```

The key line is the last: the `tool_invoke` for `send_to_user` carries
A's `principal_id`, and its `args["workspace_name"]` is `"app2-prod"`, so
Lane B computes the required permission as
`workspace:app2-prod/send_to_user` — A needs that grant.

If A lacks it, Lane B denies and the handler falls back to emitting
"❌ 无权限执行 send_to_user（请联系管理员授权）" to A via App1. (The
handler may also wish to check upfront and give a clearer "you can't
notify that user in App2" error before attempting the tool; both UX are
fine.)

### Permission model is already correct

The capability-based ACL shipped in `feature/esr-capabilities` already
supports this entire flow without modification. The new work is purely
application-layer code: one tool primitive + one handler.

## Scope estimate

- ~100 lines of Elixir (the `build_emit_for_tool("send_to_user", ...)`
  clause + workspace → adapter resolution + `permissions/0` declaration).
- ~100 lines of Python (the `cross_notify_proxy` handler — may be smaller
  depending on command grammar).
- ~80 lines of integration tests — round-trip "A sends `/send-via-app2`
  in App1 → B receives DM in App2", plus the Lane B deny case for an
  underprivileged A.
- Total: 1–2 days of focused work.

## Extensions / second-order questions

These are **not** required for the v1 handler but worth noting:

1. **Target-user authorization**: can A send to *any* `open_id` they name,
   or only to users who also hold some capability? Today there's no
   "reverse" permission check ("is B willing to receive notifications via
   App2"). For v1, assume admin-controlled grants cover this by scoping
   the handler itself (only people holding the App1 cap can use the
   cross-notify command).

2. **Message templating / redaction**: should the text pass through
   unchanged, or be wrapped ("From Alice: ...")? UX decision, not
   permission. Default to wrapping — makes provenance visible to B.

3. **Receipt / delivery confirmation**: should A get a reply in App1
   saying "delivered to B at <time>"? Nice UX; not strictly required.

4. **Direct App2 reply threading**: B replies to the notification in
   App2 — does that reply get routed back to Alice somehow, or does B
   now "own" a new thread with the bot? The spec says B with `msg.send`
   but no `session.create` would be stuck in an existing thread. A full
   bidirectional flow (A ↔ B across App1/App2) probably needs a
   dedicated "cross-workspace bridge" pattern, which is strictly
   bigger than this doc's scope and belongs in a separate future doc.

## Proposed trigger

This handler becomes worth building when the user has a concrete
operational need — e.g., a team workflow where humans coordinate across
multiple Feishu apps (different business domains), or an LLM-driven
notification bot that routes alerts from one app to recipients in
another.
