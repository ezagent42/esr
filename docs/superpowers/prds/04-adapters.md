# PRD 04 — Adapters (feishu + cc_tmux)

**Spec reference:** §5 Adapter, §10.3 sidecar relationship
**Glossary:** `docs/superpowers/glossary.md`
**E2E tracks:** A (install), C (bidirectional Feishu↔CC), D (isolation)
**Plan phase:** Phase 4

---

## Goal

Ship the two adapters v0.1 needs end-to-end: `feishu` (Feishu WS ingest + API send) and `cc_tmux` (launch tmux with CC + send-keys + capture output). Each is a separate installable Python distribution using the `@adapter` SDK from PRD 02.

## Non-goals

- Voice adapter (v0.2)
- Zellij adapter (the cc-on-zellij example is illustrative; v0.1 ships tmux)
- HTTPS webhook-receiving adapters (v0.2)
- Re-implementing cc-openclaw's sidecar business logic (stays in cc-openclaw per §10.3)

## Functional Requirements

### Common to both adapters

#### F01 — Package layout
Each adapter lives at `adapters/<name>/` with `pyproject.toml`, `src/esr_<name>/`, `esr.toml` (adapter manifest), `tests/`. **Unit test:** manual — import path resolves.

#### F02 — Factory purity
The `@adapter` class's `factory(actor_id, config)` method does not perform I/O: no network connection, no subprocess, no file write. Lazy initialisation allowed inside the instance (first `on_directive` or `emit_events` call). **Unit test (per adapter):** pass a monkeypatched `socket.socket` that raises → factory still returns an instance.

#### F03 — Capability declaration
Every adapter declares `allowed_io` in `@adapter(name=..., allowed_io=...)`. CI capability scan (PRD 02 F18) passes. **Unit test:** `tests/test_capability.py` — scan passes.

#### F04 — Manifest
`adapters/<name>/esr.toml` contains:
```toml
name = "<adapter-name>"
version = "0.1.0"
module = "esr_<name>.adapter"
entry = "<ClassName>"
allowed_io = { ... }
```
Used by `esr adapter install` (PRD 07 F05). **Unit test:** `tests/test_manifest.py` — file parses.

### Feishu adapter (`adapters/feishu/`)

#### F05 — Registration
`@adapter(name="feishu", allowed_io={"lark_oapi": "*", "http": ["open.feishu.cn"]})` on `FeishuAdapter`. Factory signature: `factory(actor_id, config) -> FeishuAdapter` where config carries `app_id`, `app_secret`. **Unit test:** `adapters/feishu/tests/test_registration.py`.

#### F06 — Lark client lazy init
First call to `self.client()` builds `lark_oapi.Client` with the provided app creds and caches it. Factory does not touch `lark_oapi.Client`. **Unit test:** inspect state after factory call — `_client is None`; after one directive — not None.

#### F07 — Directive: `send_message`
`on_directive(Directive(adapter=..., action="send_message", args={chat_id, content}))` calls Lark's `im.v1.message.create` with `receive_id_type="chat_id"`, `msg_type="text"`, serialised content. Returns `{"ok": True, "result": {"message_id": <new_id>}}` or `{"ok": False, "error": <str>}`. **Unit test:** mocked lark client, assert outgoing request shape.

#### F08 — Directive: `react`
`send_reaction` variant: calls `im.v1.message.reaction.create` with the given `msg_id` + `emoji_type`. **Unit test:** mocked lark client.

#### F09 — Directive: `send_card`
Accepts an interactive card payload (JSON-serialised); calls `im.v1.message.create` with `msg_type="interactive"`. **Unit test:** mocked lark client; verify `content` is valid card JSON.

#### F10 — Directive: `pin` / `unpin`
Calls `im.v1.pin.create` / `delete`. **Unit test:** mocked lark client.

#### F11 — Directive: unknown action
Any `on_directive(d)` with `d.action` not in the supported set returns `{"ok": False, "error": f"unknown action: {d.action}"}`. No raise. **Unit test:** unknown → error response, adapter still alive.

#### F12 — Event: WS listener
`emit_events()` is an async generator that connects to Lark's WS via `lark_oapi.ws.Client`, subscribes to `P2ImMessageReceiveV1` and `P2ImMessageReactionCreatedV1`, parses each and yields `Event(source=<uri>, event_type=..., args=...)`. **Unit test:** inject a synthetic raw WS frame; assert the generator yields the expected `Event`.

#### F13 — Event parsing: message types
For `P2ImMessageReceiveV1`, parse `msg_type` → dispatch to per-type parsers (text / post / image / file / merge_forward / interactive / sticker / share_chat / share_user / location / todo / system / hongbao / vote / video_chat / calendar / folder — mirrors cc-openclaw's `channel_server/adapters/feishu/parsers.py`). Each parser returns a normalised `(text_repr, file_path)`. Unknown types fall back to `f"[{msg_type} message]"`. **Unit test:** per type, assert parse output against known-good Feishu payloads (fixtures in `tests/fixtures/`).

#### F14 — File download hook
When an event represents a file/image/audio, `emit_events()` does NOT auto-download (spec §10.1). Instead, yields the event with `args={"msg_id", "file_key", "file_name", "msg_type"}` so a handler can choose whether to download. Downloading is triggered by a separate directive `download_file` (`on_directive`). **Unit test:** file event yields without file bytes; directive downloads to `~/.esrd/<instance>/uploads/<chat_id>/<file_name>` and returns `{"ok": True, "result": {"path": ...}}`.

#### F15 — Rate limiting
Respect Lark's documented rate limits. On 429, back off exponentially (1s, 2s, 4s, ..., capped at 30s) and retry. Directives that time out after 30s total return `{"ok": False, "error": "timeout"}` per spec §7.3. **Unit test:** mock returning 429 followed by 200; verify one retry.

### CC tmux adapter (`adapters/cc_tmux/`)

#### F16 — Registration
`@adapter(name="cc_tmux", allowed_io={"subprocess": ["tmux"]})` on `CcTmuxAdapter`. Factory signature: `factory(actor_id, config) -> CcTmuxAdapter` where config carries `start_cmd` (path to an executable that starts CC). **Unit test:** registration present.

#### F17 — Directive: `new_session`
`on_directive(Directive(adapter=..., action="new_session", args={session_name, start_cmd}))` runs `tmux new-session -d -s <session_name> <start_cmd>`. Returns `{"ok": True}` if tmux exit 0, else `{"ok": False, "error": <stderr>}`. **Unit test:** mocked subprocess; assert argv shape.

#### F18 — Directive: `send_keys`
Runs `tmux send-keys -t <session_name> "<content>" Enter`. Content is properly shell-escaped. **Unit test:** send-keys arg quoting — content with spaces, quotes, `$var`, backticks.

#### F19 — Directive: `kill_session`
Runs `tmux kill-session -t <session_name>`. **Unit test:** mocked.

#### F20 — Directive: `capture_pane`
Runs `tmux capture-pane -t <session_name> -p` and returns `{"ok": True, "result": {"content": <str>}}`. Useful for debug replay / inspect. **Unit test:** mocked.

#### F21 — Event: output monitoring
`emit_events()` monitors tmux output for lines matching a sentinel pattern (e.g. `^\[esr-cc\] `) — the launched CC process emits these as its structured output. Each matched line yields an `Event(source=..., event_type="cc_output", args={"session": ..., "text": ...})`. Non-sentinel lines are ignored (don't flood the event stream with terminal noise). **Unit test:** feed sample tmux output; assert sentinel lines → events, others skipped.

#### F22 — Tmux availability check
On factory call, do NOT check for tmux (keeps factory pure). On first directive, if `tmux --version` fails, return `{"ok": False, "error": "tmux not installed"}` to every subsequent directive. Log once. **Unit test:** mocked env without tmux → graceful error.

## Non-functional Requirements

- **feishu adapter:** directive round-trip p95 < 200 ms excluding Lark API latency; WS reconnect within 10s on network blip
- **cc_tmux adapter:** `send_keys` completes < 50 ms; `capture_pane` < 100 ms
- Both adapters import only modules declared in `allowed_io`; capability scan is green

## Dependencies

- PRD 02 (SDK) for `@adapter`, `AdapterConfig`, `Directive`, `Event`
- PRD 03 (IPC) for `adapter_runner.py` to host both

## Unit-test matrix

| FR | Test file | Test name |
|---|---|---|
| F01-F04 | shared meta | manual / linting |
| F05 | `adapters/feishu/tests/test_registration.py` | adapter registered |
| F06 | `adapters/feishu/tests/test_client.py` | lazy init |
| F07 | `adapters/feishu/tests/test_directives.py::test_send_message` | mocked lark |
| F08 | same | `test_react` |
| F09 | same | `test_send_card` |
| F10 | same | `test_pin_unpin` |
| F11 | same | `test_unknown_action` |
| F12 | `adapters/feishu/tests/test_events.py` | WS yield Event |
| F13 | same | parsers per msg_type (fixtures) |
| F14 | `adapters/feishu/tests/test_download.py` | file event + download directive |
| F15 | `adapters/feishu/tests/test_ratelimit.py` | 429 retry |
| F16 | `adapters/cc_tmux/tests/test_registration.py` | registered |
| F17 | `adapters/cc_tmux/tests/test_directives.py` | new_session mocked |
| F18 | same | send_keys quoting |
| F19 | same | kill_session |
| F20 | same | capture_pane |
| F21 | `adapters/cc_tmux/tests/test_events.py` | sentinel parsing |
| F22 | `adapters/cc_tmux/tests/test_env.py` | missing tmux |

## Acceptance

- [x] All 22 FRs have passing unit tests — feishu + cc_tmux matrix complete
- [x] `esr adapter install ./adapters/feishu/` + `list` tested via test_adapter_runner.py + test_adapter_manifest.py
- [x] Same for `cc_tmux` (test_cli_install.py covers both)
- [x] Capability scan clean — test_capability.py per-adapter
- [ ] Integration: feishu + cc_tmux round-trip exercised via scripts/final_gate.sh --mock (Track C)

---

*End of PRD 04.*
