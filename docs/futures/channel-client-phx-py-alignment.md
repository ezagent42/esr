# ChannelClient — align self-host with phx-py reference

**Status**: future work. Triggered by PR-21l heartbeat bug post-mortem.
**Discovered**: 2026-04-29, during ESR助手 / ESR开发助手 onboarding bootstrap when `/help` produced no DM response — `_ipc_common.reconnect run_one disconnected` cycled every ~65 s.
**Relates to**: `py/src/esr/ipc/channel_client.py`, [`phx-py`](https://github.com/Phoenix-Channels-Python/phx-py).

---

## 1. Origin

`py/src/esr/ipc/channel_client.py` is a hand-rolled Phoenix Channels v2 client. We chose self-host over a dependency for three reasons that still hold:

1. ESR envelopes are spec §7.5 shaped (`{kind, source, payload, …}`), not generic Phoenix push payloads.
2. The cross-process telemetry hook expects every frame to log through ESR's buffer.
3. F05 disconnect/reconnect semantics: pushes during a disconnected window queue into `_pending_pushes` rather than raise.

The cost of self-hosting is that **every "Phoenix client must do X to stay alive" requirement is implicit, not enforced**. PR-21l caught one such gap (heartbeat) only after a live deploy silently dropped Feishu inbound for ~1 hour.

## 2. What was broken

`ChannelClient.connect()` opens the WS and starts `_read_loop` but never sends a periodic heartbeat. Phoenix's WebSocket transport (`Phoenix.Endpoint` `socket "/adapter_hub/socket"`) defaults to a 60 s idle timeout. After ~60 s of no client→server traffic, the server closes the connection.

`_ipc_common.reconnect.reconnect_loop` faithfully reconnects, producing a steady ~65 s churn (60 s idle + 5 s backoff) where any inbound Feishu event arriving in the gap was dropped. PR-21l fixes this with a `_heartbeat_loop` task sending `[null, ref, "phoenix", "heartbeat", {}]` every 30 s.

Heartbeat was the obvious one, but **other "Phoenix client must do X" requirements are likely also missing or wrong**. We should systematically audit against a reference.

## 3. Reference: phx-py

[phx-py](https://github.com/Phoenix-Channels-Python/phx-py) is the most actively maintained Python Phoenix Channels client (last 2024 update vs. the others' 2018-2022). It's MIT-licensed and small enough to read end-to-end.

It explicitly handles:

| Concern | phx-py | ESR ChannelClient (pre PR-21l) | After PR-21l |
|---|---|---|---|
| Heartbeat | 30 s, configurable | ❌ none | ✅ 30 s, hard-coded |
| Heartbeat ref tracking | uses incrementing `ref` per heartbeat | n/a | ✅ same |
| Heartbeat shape | `[null, ref, "phoenix", "heartbeat", {}]` | n/a | ✅ same |
| Reconnect on close | exponential backoff (configurable schedule) | exists in `_ipc_common.reconnect` (separate module) | ✅ unchanged |
| Re-join after reconnect | re-sends `phx_join` for each previously-joined topic | exists (`_topic_join_refs` + `_join_internal`) | ✅ unchanged |
| Pending push during disconnect | drops with warning | ✅ buffers in `_pending_pushes` (PR-K F05) | ✅ unchanged |
| Channel event handlers | per-topic via `Channel.on/2` | per-topic via `_topic_handlers` | ✅ unchanged |
| Server push timeout | configurable | ❌ no per-call timeout (unrelated to F05) | ❌ still missing |
| Connection state events | `socket.on("open"/"close"/"error")` | ❌ no observability hooks | ❌ still missing |

PR-21l closed the heartbeat gap. Two known gaps remain (server push timeout, connection state events) plus likely-unknown gaps that an audit would surface.

## 4. Proposed work (not in current scope)

Pick whichever is most productive:

### 4.a — Audit + cherry-pick (recommended)

- Read phx-py end-to-end (the client is ~600 LOC).
- For each behavior in the table above, decide: ESR matches → leave; ESR diverges → port phx-py's pattern (or document why we intentionally diverge).
- Specific concrete tasks:
  - Add per-call timeout to `client.call/3`. Today `client.call` blocks indefinitely if the server never replies. phx-py uses a default 5 s timeout configurable per call.
  - Add `socket.on("open")`/`socket.on("close")` callbacks. ESR currently has the `_is_disconnected` flag but no way for callers to react to state transitions (e.g. for telemetry, log levels).
  - Surface heartbeat misses as a metric. phx-py exposes `last_heartbeat_at`; ESR could expose the same so PR-N-style operator DMs can warn on connection trouble.

### 4.b — Replace ChannelClient with phx-py + thin ESR adapter

Strip `ChannelClient` to a thin facade that wraps phx-py and adds the three ESR-specific concerns (envelope shape, telemetry hook, F05 push buffering). Bigger change; loses the audit value of (4.a) but ensures we never re-hit a phx-py-already-solves-this bug.

Estimated cost: ~150-200 LOC churn on top of phx-py (~50 LOC of facade).

Estimated benefit: every future Phoenix protocol revision (Phoenix 1.8+) lands automatically when we bump phx-py.

### 4.c — Just fix heartbeat metrics (smallest)

Stop here at PR-21l. Heartbeat works; F05 buffering works; reconnect works. Add one observability feature only: a `last_inbound_at` / `last_heartbeat_ack_at` pair so operators can detect "channel alive but going stale" via telemetry.

## 5. Decision pending

Pick (4.a), (4.b), or (4.c) when scheduling next phase of IPC hygiene work. Default tilt: **(4.a)** — gives us a forced audit of every Phoenix client behavior we've hand-rolled, vs. (4.b) which trades that audit for a dependency.

Until decided, PR-21l's heartbeat is sufficient: live ESR助手 / ESR开发助手 onboarding works end-to-end, no observable churn.

## 6. Discovery context

The bug surfaced in this exact sequence:

1. Bootstrap users.yaml + workspaces.yaml schema migration (PR-21a-c).
2. Restart both esrd via `launchctl kickstart`.
3. User sends `/help` in ESR助手 chat.
4. Expected: chat-guide DM (PR-N + PR-21f update) replying with `/new-workspace` instructions.
5. Observed: complete silence.
6. Diagnosis: `/tmp/esr-worker-adapter-feishu-esr_helper.log` showed reconnect-every-65 s pattern. Cross-checked vs. esrd `launchd-stdout.log` `handler_hello` flood at the same cadence. The "subprocess connected to esrd" lsof check was a red herring — the connection existed but only for ~60 s windows.
7. Inbound Feishu events arriving inside the gap were dropped by the OS-level WebSocket close before Python's `_read_loop` saw them.
8. PR-21l shipped 2026-04-29 (#87). Verified end-to-end: 18:05:04 user sends `/help` → 18:05:05 directive_ack ok=true → 18:05:06 `im.message.message_read_v1` (user read the DM).

Lesson for future self-hosted protocol implementations: **even small protocols have implicit liveness contracts. Read a reference implementation end-to-end before declaring the rewrite "feature-complete".**
