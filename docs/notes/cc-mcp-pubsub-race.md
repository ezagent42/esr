# CCProcess send_input → cc_mcp PubSub race on session auto-create

## TL;DR

When a session is auto-created from a user's first inbound message, the
handler's `send_input` action broadcasts `{:notification, envelope}` on
`cli:channel/<session_id>` before cc_mcp has joined that topic. Phoenix
drops the message silently. Claude never sees the user's first message
— it only sees its own auto-confirm "1" keystroke.

Scenario 01 step 2 fails at `assert_mock_feishu_sent_includes "ack"`
because of this race (not the env-injection fix in T12-comms-3, which
worked — tmux now launches claude with `ESR_SESSION_ID` etc., and
cc_mcp now successfully registers on `cli:channel/<sid>`).

## Evidence (scenario 01 probe, 2026-04-24 23:07)

`/tmp/esrd-pr7-1777043231-52903/e2e-pr7-*/logs/stdout.log`:

```
t+0.6s  line 32: inbound arrives on adapter:feishu
        ("Please reply with exactly the three letters: ack")
t+0.6s  line 33: session_router: auto-created session MKWQ7SFOWDVC3FKVYBAQ
t+0.7s  line 35: handler_reply from cc_adapter_runner:
        actions=[{type: "send_input", text: "Please reply with exactly the three letters: ack"}]
        → cc_process broadcasts {:notification, envelope} on
          "cli:channel/MKWQ7SFOWDVC3FKVYBAQ"   ← LOST
          (Phoenix.PubSub has zero subscribers on that topic)
t+~10s  line 111: cc_mcp JOINED cli:channel/MKWQ7SFOWDVC3FKVYBAQ
t+~10s  line 113-114: cc_mcp pushes session_register    ← too late
```

The tmux pane shows claude responding "I see just '1' — could you let
me know what you'd like help with?" — because the only input claude
received was the trust-folder auto-confirm keystroke scheduled by
`TmuxProcess.schedule_startup_keys`, not the user's message.

## Architectural context

Pre-T11b.6: `CCProcess.dispatch_action({"type"=>"send_input", "text"=>t})`
sent `{:send_input, t}` to the `TmuxProcess` neighbor, which buffered
keystrokes via tmux's stdin. Even if claude was still booting, tmux
held the bytes in its terminal buffer and claude consumed them when
ready. No race.

T11b.6 swapped tmux stdin for a pubsub notification so CC's inbound
arrives as a `<channel>` tag via cc_mcp's `notifications/claude/channel`
instead of being typed into the terminal. That design assumes cc_mcp
is always already listening before dispatch_action fires — which is
true for subsequent messages in a live session, but NOT for the very
first message that triggered the auto-create.

## Fix options

**Option A — hybrid**: keep the pubsub notification AND also send
`{:send_input, text}` to the tmux neighbor. Tmux's terminal buffer
acts as the fallback when cc_mcp hasn't joined yet. Partially reverses
T11b.6 but preserves the symmetry principle for subsequent messages.

**Option B — buffer + flush on ready**: cc_process keeps a pending list
of notifications. ChannelChannel, on successful session_register,
broadcasts `{:cc_mcp_ready, session_id}` on a control topic that
cc_process subscribes to; on receipt, cc_process re-broadcasts all
pending notifications and clears the buffer.

**Option C — delayed redelivery**: SessionRouter's `redeliver_triggering_envelope`
(currently fired immediately after pipeline spawn in T7) waits for
cc_mcp's session_register before redelivering the inbound envelope to
FCP. FCP's handle_upstream runs, triggers the handler, and the reply
arrives while cc_mcp is confirmed ready.

Option C is the cleanest — it respects T11b.6's architectural intent
and uses the existing redelivery hook. Risk: the "temporary peer is
alive and ready" signal needs to propagate from ChannelChannel back
to SessionRouter; the simplest path is a `Phoenix.PubSub.subscribe`
in SessionRouter for `"cli:channel/<sid>"` before the redelivery,
waiting on a `{:cc_mcp_ready, sid}` message with a bounded timeout.

## See also

- `runtime/lib/esr/peers/cc_process.ex:225` — `dispatch_action(send_input, …)`
  (the broadcast point)
- `runtime/lib/esr/session_router.ex:224` — `redeliver_triggering_envelope`
  (the hook to delay)
- `runtime/lib/esr_web/channel_channel.ex` — ChannelChannel's
  session_register handler (where the "ready" signal originates)
- `docs/notes/tmux-env-propagation.md` — sibling note on the env fix
  that unblocked this investigation
