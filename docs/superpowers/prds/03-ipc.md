# PRD 03 — IPC (Phoenix Channels + Python Client + Handler Worker)

**Spec reference:** §7 IPC Protocol
**Glossary:** `docs/superpowers/glossary.md`
**E2E tracks:** A, B, C, E, G (all depend on IPC working)
**Plan phase:** Phase 3

---

## Goal

Build the Python↔Elixir IPC layer. Elixir side (Phoenix channels for adapter + handler topics) lives in PRD 01; this PRD focuses on the Python side of the wire plus the envelope format that both sides must agree on.

## Non-goals

- Authentication / JWT / mTLS (v0.2)
- Multi-node distribution (v0.2; one WS per Python process talking to one Elixir node)
- Non-Phoenix transports (stdio, gRPC) — Phoenix Channels per spec choice

## Functional Requirements

### F01 — Envelope schema constants
`esr.ipc.envelope` defines string constants for envelope types: `"event"`, `"directive"`, `"directive_ack"`, `"handler_call"`, `"handler_reply"`. **Unit test:** none; constants used below.

### F02 — Envelope builders
Helper functions per envelope type:
- `make_event(source, event_type, args) -> dict`
- `make_directive_ack(id_, source, ok, result=None, error=None) -> dict`
- `make_handler_reply(source, id_, new_state, actions) -> dict`
Every builder includes `id` (uuid with type prefix, e.g. `e-…`), `ts` (RFC 3339), `type`, `source` (full `esr://` URI of the emitter), `payload`. **Unit test:** `tests/test_envelope.py` — structure + id prefix / ts parse.

### F03 — Action serialisation
`esr.ipc.envelope.serialise_action(Action) -> dict` turns `Emit / Route / InvokeCommand` into a JSON-ready dict with a `type` discriminator (`emit`, `route`, `invoke_command`). **Unit test:** round-trip serialise + deserialise reproduces the Action.

### F04 — Phoenix channel client
`esr.ipc.channel_client.ChannelClient(url)` connects to a Phoenix Channels endpoint. Exposes `connect()`, `join(topic, on_msg: Callable)`, `push(topic, event, payload)`, `close()`. Frame format: `[join_ref, ref, topic, event, payload]` per Phoenix wire protocol. Auto-increments ref; multiplexes many topics over one WS. **Unit test:** `tests/test_channel_client.py` — mocked server accepts join + push.

### F05 — Channel client error handling
On WS disconnect, `ChannelClient` attempts reconnect with exponential backoff (1s, 2s, 4s, 8s, capped at 30s). Queues pending `push` calls up to 1000 entries during disconnect; overflow drops oldest. Emits logger warnings. **Unit test:** force-close the mocked server, verify reconnect, pending messages flush.

### F06 — Join reply
When joining a topic, Phoenix replies with `{"status": "ok", "response": {}}` on a phx_reply event. The client awaits this before considering the join complete. `ChannelClient.join` is an async function that doesn't return until the server acks. **Unit test:** client blocks until ack arrives.

### F07 — Handler worker entry point
`esr.ipc.handler_worker.run(url, module)` is the entry for the Python worker process. Joins `handler:<module>/<worker_id>`. Loop:
1. Receive `handler_call` envelope
2. Deserialise `state` (construct the registered pydantic model) and `event` (construct `Event`)
3. Look up handler in `HANDLER_REGISTRY`; if missing, reply with `{"error": "handler_not_registered"}`
4. Invoke: `new_state, actions = handler_fn(state, event)`
5. Serialise and reply with `handler_reply` envelope
**Unit test:** `tests/test_handler_worker.py` — mocked channel, synthetic `handler_call`, assert `handler_reply` contents.

### F08 — Handler worker exception handling
Any exception from the handler body is caught, logged, and surfaced in the reply as `{"error": {"type": "<cls>", "message": "<msg>"}}`. Never crashes the worker (Elixir side reserves "worker crashed" for unexpected exits, e.g. segfaults). **Unit test:** handler raises → reply contains error payload → worker stays alive.

### F09 — Adapter process entry point
`esr.ipc.adapter_runner.run(adapter_name, instance_id, config, url)` is the entry for a Python adapter OS process. Joins `adapter:<name>/<instance_id>`. Instantiates the adapter via `ADAPTER_REGISTRY[name].cls.factory(...)`. Runs two concurrent tasks: **(a)** consume directive envelopes from the channel and invoke `instance.on_directive(directive)`, returning `directive_ack`; **(b)** consume events from `instance.emit_events()` (async generator) and push them as `event` envelopes. **Unit test:** `tests/test_adapter_runner.py` — mocked channel + mocked adapter, verify both tasks run.

### F10 — Adapter directive ordering
Directives for the same adapter instance are processed strictly FIFO (one at a time, not concurrent). Events emitted from `emit_events()` may interleave. **Unit test:** submit directives D1, D2, D3 with artificial delays; verify acks arrive in D1, D2, D3 order.

### F11 — IPC URL discovery
Python processes find the Phoenix endpoint URL via env var `ESR_RUNTIME_URL` (default `ws://localhost:4001/adapter_hub/socket/websocket`). CLI commands inherit `ESR_RUNTIME_URL` from `esr use` (PRD 07 F01). **Unit test:** `tests/test_url_discovery.py` — default + override.

### F12 — Envelope source field correctness
Every envelope sent from Python carries `source` = the full `esr://localhost/(handler|adapter)/<id>` URI. The Elixir side verifies this against the expected topic; mismatch emits `[:esr, :ipc, :source_mismatch]` and rejects the message. **Unit test:** client-side; the Elixir side has its own in PRD 01.

### F13 — Integration smoke test
With a live `esrd-dev` running, a script that:
1. Starts a handler worker for a `noop.handler` module that returns `(state, [])`
2. Injects a `handler_call` via the Elixir side
3. Observes the `handler_reply`
Returns within 2 s. Gated behind `ESR_E2E_RUNTIME=1` env var. **Unit test:** `tests/test_ipc_integration.py` (skipif env not set).

## Non-functional Requirements

- Handler call round-trip p95 < 20 ms warm (measured by F13)
- Adapter directive round-trip p95 < 10 ms
- Reconnect gracefully within 60 s on transient network failure

## Dependencies

- PRD 01 F09-F12 must land first to give the Python side an Elixir counterpart to talk to

## Unit-test matrix

| FR | Test file | Test name |
|---|---|---|
| F02 | `py/tests/test_envelope.py` | builder shape + id prefix |
| F03 | `py/tests/test_envelope.py` | action round-trip |
| F04 | `py/tests/test_channel_client.py` | join + push |
| F05 | `py/tests/test_channel_client.py` | reconnect on close |
| F06 | `py/tests/test_channel_client.py` | blocking join |
| F07 | `py/tests/test_handler_worker.py` | handler_call → handler_reply |
| F08 | `py/tests/test_handler_worker.py` | exception path |
| F09 | `py/tests/test_adapter_runner.py` | directive + event tasks |
| F10 | `py/tests/test_adapter_runner.py` | FIFO directives |
| F11 | `py/tests/test_url_discovery.py` | env + default |
| F12 | `py/tests/test_envelope.py` | source URI field |
| F13 | `py/tests/test_ipc_integration.py` | live runtime round-trip |

## Acceptance

- [x] All 13 FRs have passing unit tests (F01-F12 unit-tested, F13 exercised by final_gate.sh --live pipeline)
- [x] Live runtime round-trip exercised via scripts/final_gate.sh --live (4-artifact nonce correlation per spec v2.1 §4.1.1)
- [ ] Reconnect across a network blip exercised in scripts/final_gate.sh --live (L2 esrd log shows reconnect + L4 nonce still lands)

---

*End of PRD 03.*
