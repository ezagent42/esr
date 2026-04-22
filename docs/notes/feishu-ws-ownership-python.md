# Feishu WebSocket Ownership: Python, Not Elixir

## Context

Discovered 2026-04-22 during PR-2 expansion for the Peer/Session refactor. The plan's original outline for PR-2 said "`FeishuAppAdapter (Peer.Stateful; owns WS)`" — implying the Elixir side would terminate the Feishu WebSocket. Inspection of the current codebase showed this is not the case and would be a significant rewrite.

## Observation

Today's Feishu event flow:

```
Feishu open-platform
     │ WebSocket (wss://open.feishu.cn/...)
     ▼
py/src/esr/ipc/adapter_runner.py  [Python process, spawned per adapter instance]
     │ (uses lark.client / MsgBotClient Python SDK for WS frame handling,
     │  signature verification, event routing)
     │
     │ Forwards decoded events as Phoenix channel frames on topic
     │   adapter:feishu/<instance_id>
     ▼
Phoenix.PubSub (Elixir)
     │
     ▼
EsrWeb.AdapterChannel  [Elixir; runtime/lib/esr_web/adapter_channel.ex]
     │
     ▼
Esr.AdapterHub.Registry → looks up the owning PeerServer
     │
     ▼
PeerServer (Elixir) handles the event
```

The Elixir side never sees raw Feishu WS frames. It only sees already-decoded, already-authenticated Phoenix-channel messages.

## Implication

PR-2's `Esr.Peers.FeishuAppAdapter` redefines its role: it is the single Elixir consumer of `adapter:feishu/<app_id>` Phoenix-channel frames. It replaces the `Esr.AdapterHub.Registry` lookup hop (which itself gets deleted in PR-2 P2-16) and dispatches events to per-session `FeishuChatProxy` pids via `Esr.SessionRegistry.lookup_by_chat_thread/2`.

The Python-side `adapter_runner` + `MsgBotClient` stays untouched in PR-2. PR-4b (adapter_runner split) refactors the Python side but keeps WS ownership there.

## Why it stays in Python (long-term answer)

1. **Lark/Feishu SDK is Python-centric**: `lark-oapi` has first-class Python support, minimal Elixir support. Rewriting WS client + signature verification + event routing in Elixir would be 500+ LOC of non-trivial code + ongoing SDK-version-tracking burden.
2. **Signature verification has Python-specific crypto helpers** used by the SDK.
3. **No operational motivation**: the Python → Phoenix channel hop is currently ~1ms of latency overhead; not a bottleneck.
4. **Consolidates with other Python sidecars**: adapter_runner is the natural home for Python-heavy integration (Lark, voice, TTS, ASR, etc. — all have stronger Python than Elixir libs).

## Future (if this ever flips)

Would only be worth doing if:
- A new Feishu-tier feature requires Elixir-side WS frame inspection that Python-side forwarding can't express
- The Python process becomes a reliability bottleneck (crashes / memory)
- A move to pure-BEAM deployment (no Python sidecars at all) becomes a strategic priority

None of these are current drivers. **Status: not planned. Reevaluate if those conditions change.**

## Related

- Plan P2-2 (`FeishuAppAdapter` consumes Phoenix channel, not raw WS): `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`
- PR-4b adapter_runner split: same plan
- Spec §4.1 FeishuAppAdapter card may need a sentence clarifying the Phoenix-channel relationship; file as a minor spec refinement if it causes confusion later
