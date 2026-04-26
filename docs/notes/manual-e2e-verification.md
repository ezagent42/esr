# Manual E2E verification — humans-driving Feishu against a real esrd

Captured 2026-04-26 alongside the Lane A drop PR. Complements the
automated `make e2e` suite (which runs against `mock_feishu`) by
exercising the full live stack: real Feishu Open API, real chat
membership, real claude in tmux.

## When to run

Before any release that touches:
- `runtime/lib/esr/peers/feishu_*.ex`
- `runtime/lib/esr/peer_server.ex` (auth gate or deny-DM dispatch)
- `adapters/feishu/src/esr_feishu/adapter.py`
- `adapters/cc_mcp/src/esr_cc_mcp/`
- the `<channel>` tag shape
- `Esr.SessionRegistry`, `Esr.Workspaces.Registry`, capabilities.yaml shape

Or after any infra-side change to gateway / channel-server / tmux
plumbing on the dev workstation.

## Before you start

1. The release candidate is on `main`; you're going to point a real
   esrd at it.
2. You have your Feishu test account + admin access to the bot you
   want to test against.
3. The dev workstation has both apps configured in
   `${ESRD_HOME}/<instance>/adapters.yaml` with their real
   `cli_<app_id>` / `app_secret` (not mock).
4. `${ESRD_HOME}/<instance>/workspaces.yaml` maps the chats you'll
   test against to workspace names.
5. `${ESRD_HOME}/<instance>/capabilities.yaml` grants
   `workspace:<ws>/*` (or `["*"]`) to your `ou_<your-open-id>`.

If any of those is missing, fix it before continuing — the failure
mode is "stranger DM gets silently denied" which is correct
behaviour but indistinguishable from "esrd is broken."

## Single-app DM scenario

**What you're testing:** the most common production path —
1:1 DM with the bot, simple text reply, simple file send.

### Steps

1. **Start clean esrd.**
   ```bash
   cd /path/to/repo
   ESRD_HOME=/tmp/esrd-manual-$(date +%s) ESR_INSTANCE=manual \
     bash scripts/esrd.sh start --instance=manual
   ```
   Watch `${ESRD_HOME}/manual/logs/stdout.log` for `JOINED adapter:feishu/<your-app-instance>` —
   means your Feishu adapter sidecar connected. If you see
   `connect failed ... Errno 49`, your workstation is in a
   TIME_WAIT-pool exhaustion state — see
   `docs/notes/futures/multi-app-deferred.md` §6.

2. **Send a plain text from your Feishu account to the bot.**
   Just type "hello" in your DM with the bot.

   Expected:
   - Bot reacts to your message with the 👀 (or 🔥, depending on
     agent yaml) emoji within 2-3 seconds.
   - Bot replies with whatever your agent's prompt says it should
     reply with for "hello" (typically a friendly ack).

   If no react: channel-server is the suspect. Check
   `~/.openclaw/logs/channel-server.log` and
   `~/.openclaw/logs/gateway.log` for `Errno 49` or `502 Bad Gateway`.

   If react but no reply: claude in tmux is the suspect. Find the
   session via `esr actors list | grep thread:`, then attach
   to its tmux pane (`tmux -S /tmp/esr-cc.sock attach -t esr_cc_<N>`)
   to see what claude is doing.

3. **Send a slash-command-shaped message.** "`/help`" or
   "`what tools do you have`" — exercises the tool-discovery path
   in cc_mcp.

   Expected: claude lists available tools in its reply (`reply` /
   `react` / `send_file`).

4. **Trigger the `send_file` tool.** "Please send me your
   capabilities.yaml" or similar prompt that should trigger
   `send_file`.

   Expected:
   - You receive a file attachment in the chat.
   - The file's content matches what was actually on disk.

5. **End the session.** Type "/end" or whatever your agent maps to
   session_end. Then `esr actors list` should show zero
   `thread:<sid>` entries.

   Expected:
   - Bot acknowledges the end (text varies by agent).
   - `actors list` is clean.

### What you've verified

- Inbound: Feishu cloud → channel-server → gateway → adapter sidecar
  → Phoenix channel → FCP → CC pipeline (single app, single
  workspace). The Lane B gate at `peer_server.ex:236-274` allowed
  your inbound (verify via `grep "capabilities, :denied" stdout.log`
  — should be empty for your principal).
- Outbound: CC mcp → cc_mcp → Phoenix channel → FCP →
  `forward_reply_pass_through` → FAA → adapter → Feishu Open API
  POST → message in chat.
- Tool-call round-trip: same path with structured `tool_invoke` /
  `tool_result`.
- Cleanup: session_end propagates through SessionRegistry +
  TmuxProcess.terminate.

## Multi-app group chat scenario

**What you're testing:** PR-A's multi-app cross-app forward + auth
gate. Requires two configured apps (e.g. `feishu_app_dev` +
`feishu_app_kanban`) and you're a member of group chats under both.

### Setup

1. Configure two apps in `adapters.yaml` and verify both join via
   `JOINED adapter:feishu/<each>` lines in stdout.log.
2. Configure `workspaces.yaml` with chats under both apps. Example:
   ```yaml
   workspaces:
     ws_dev:
       chats:
         - {chat_id: oc_<your_dev_chat>, app_id: feishu_app_dev, kind: group}
     ws_kanban:
       chats:
         - {chat_id: oc_<your_kanban_chat>, app_id: feishu_app_kanban, kind: group}
   ```
3. `capabilities.yaml`: grant your principal `["*"]` so all paths
   succeed (or use scoped caps to test the deny path — see "negative
   path" below).

### Steps (happy path)

1. **In the dev group chat, ask the bot to relay something to
   kanban.** Naturally — *not* "send literal X to chat-Y if you
   fail" or anything that looks like prompt-injection (CC will
   refuse — see `docs/notes/cc-cross-app-refusal.md`). Phrase it
   like a normal cross-team request:
   > "@bot please post 'sprint status: blocked on review' to the
   > kanban room"

   Expected:
   - Bot replies in the dev chat acknowledging it'll post.
   - **The status message lands in the kanban chat** (not in dev).
   - kanban-side receives a normal-looking message — doesn't see
     the dev-chat principal info.
   - `grep "FCP cross-app" stdout.log` shows zero entries (allow
     path doesn't log a deny).

2. **Reply directly in the kanban chat.** This auto-creates a
   second session for ou_<you> in the kanban app.

   Expected: bot replies normally in kanban chat. The two sessions
   (dev + kanban) coexist; check with `esr actors list` — you'll
   see two `thread:<sid>` entries with different workspace names.

3. **Cross-reference with the SessionRegistry 3-tuple.** Run:
   ```bash
   grep "session_register" stdout.log | tail -5
   ```
   Each entry shows `chats: [{chat_id, app_id, kind}]` — verify the
   two sessions have distinct `app_id` (`feishu_app_dev` vs
   `feishu_app_kanban`).

### Steps (negative path: forbidden cross-app)

Tests Lane B's auth gate denies cross-app reply when the principal
lacks the target workspace's `msg.send`.

1. Edit `capabilities.yaml`: change your principal from `["*"]` to
   `["workspace:ws_dev/*"]` (only ws_dev). Save. The runtime
   `fs_watch` reloads within 2s; you can confirm via
   `grep "capabilities: loaded" stdout.log`.

2. **Same prompt as happy-path step 1** ("@bot please post X to
   the kanban room").

   Expected:
   - Bot replies in dev chat that it tried but couldn't (CC's own
     wording — won't be a fixed string).
   - **Kanban chat receives nothing.**
   - `grep "FCP cross-app deny type=forbidden" stdout.log` shows
     a line with `principal_id="ou_<you>"`, `workspace="ws_kanban"`,
     `perm="workspace:ws_kanban/msg.send"`.

3. **Restore wildcard cap** in `capabilities.yaml` before moving on.

### Steps (negative path: deny DM rate-limit)

Tests Lane B's deny-DM dispatch + 10-min suppression for an
unauthorized stranger.

1. Have a colleague (or a second Feishu account you control) DM the
   bot. Their `open_id` should NOT be in `capabilities.yaml`.

   Expected:
   - The colleague receives **one** message:
     `你无权使用此 bot，请联系管理员授权。`
   - `grep "capabilities, :denied" stdout.log` shows a line with
     their `open_id`.
   - `grep "dispatch_deny_dm" stdout.log` shows the runtime
     dispatched the directive to FAA.

2. **Have the same colleague send a second message within 10 minutes.**

   Expected:
   - Their message reaches Feishu, channel-server forwards it,
     runtime denies it (visible in stdout.log telemetry), but
     **no second deny DM fires** (rate-limit suppressed it).

3. **Wait > 10 minutes, send a third message.**

   Expected: deny DM fires again (rate-limit window reset).

### Steps (cleanup)

End sessions for both apps. `esr actors list` should be empty for
both `thread:` entries.

### What you've verified

- Multi-app routing: SessionRegistry 3-tuple `(chat_id, app_id,
  thread_id)` correctly partitions sessions.
- Cross-app dispatch: FCP's `dispatch_cross_app_reply` finds the
  target FAA, dispatches via `{:outbound, _}`, and the kanban
  adapter actually receives + sends.
- Auth gate: `Capabilities.has?(principal, "workspace:<target>/msg.send")`
  denies when expected, and the deny telemetry shape matches
  spec.
- Lane B deny-DM: `peer_server.ex` deny path → FAA
  `:dispatch_deny_dm` → adapter outbound → real Feishu API. No
  Python-side gate in the loop (Lane A is gone).

## What's NOT covered by manual

- High-load behavior (concurrent sessions, deny storms): use
  `make e2e` for these.
- Cap reload race conditions (ETS wipe window, etc.): tracked in
  `docs/notes/futures/multi-app-deferred.md` §1.
- Chat-membership rejection from Feishu's side (app-not-in-chat
  errors): need to actually remove the bot from a chat and DM it,
  which requires admin coordination. Treat as quarterly check.

## When something goes wrong

1. **Bot doesn't react at all** — channel-server / gateway issue.
   `~/.openclaw/logs/`. Probably `Errno 49` (port-pool exhaustion)
   or `502 Bad Gateway` (proxy issue — confirm
   `no_proxy=.feishu.cn,...` is set in the gateway plist).
2. **Bot reacts but no reply in 30s** — CC stuck. Find the tmux
   pane and attach.
3. **Reply in wrong chat** — FCP routing bug. Capture
   `grep "tool_invoke" stdout.log` and the `<channel>` notification
   payload from the cc_mcp side.
4. **Deny DM doesn't fire for stranger** — Lane B `dispatch_deny_dm`
   broken. Check `grep "Lane B deny: no FAA registered"
   stdout.log` — if present, the FAA peer registration is failing;
   check `Esr.PeerRegistry` lookup at startup.
5. **Cap edits not picked up** — FileLoader watcher not running.
   Check for `fs_watch` errors in stdout.log; restart esrd as a
   workaround.

## See also

- Automated harness: `make e2e` (scenarios 01–04, mock_feishu)
- Spec for current auth: `docs/superpowers/specs/2026-04-25-drop-lane-a-auth.md`
- Migration note: `docs/notes/auth-lane-a-removal.md`
- Cross-app refusal: `docs/notes/cc-cross-app-refusal.md`
- TIME_WAIT pattern: `docs/notes/e2e-no-time-wait-storms.md`
