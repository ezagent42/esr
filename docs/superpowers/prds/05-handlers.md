# PRD 05 — Handlers (feishu_app, feishu_thread, tmux_proxy, cc_session)

**Spec reference:** §4 Handler, §6.2 feishu-thread-session topology, §9 E2E Tracks B/C
**Glossary:** `docs/superpowers/glossary.md`
**E2E tracks:** B (`/new-thread` InvokeCommand), C (bidirectional flow), H (correctness)
**Plan phase:** Phase 5

---

## Goal

Ship the four handler modules that, together, implement the feishu-to-cc flow: recognise `/new-thread`, route messages, manage dedup, wire tmux send/receive. Each handler is a **pure function** returning `(new_state, actions)`; no I/O in handler code.

## Non-goals

- Voice handler (v0.2)
- Any LLM routing / Claude API — that's done by the CC process inside tmux (opaque to ESR v0.1)
- Permission / authorization (stays in cc-openclaw's sidecar; see §10.3)

## Functional Requirements

### Cross-handler concerns

#### F01 — Handler package layout
Each handler at `handlers/<name>/` has: `pyproject.toml` (`name = "esr-handler-<name>"`, `dependencies = ["esr"]`), `src/<name>/on_msg.py`, `src/<name>/state.py`, `esr.toml` (manifest), `tests/`. **Unit test (shared):** install path resolves; manifest parses.

#### F02 — Handler manifest
`esr.toml` contains:
```toml
name = "<handler-name>"
version = "0.1.0"
module = "<name>.on_msg"
entry = "on_msg"
actor_type = "<actor_type>"
allowed_imports = []  # plus esr / typing / dataclasses / pydantic / enum by default
```
Used by `esr handler install`. **Unit test:** manifest loads.

#### F03 — State model frozen
All handler state inherits pydantic `BaseModel` with `model_config = {"frozen": True}`. Every mutation goes through `model_copy(update=...)`. **Unit test (per handler):** `tests/test_state_frozen.py` — direct attribute assignment raises `ValidationError`.

#### F04 — Purity check 1 passes
Every handler module passes `esr-lint`'s import-allow-list check (PRD 02 F16). **Unit test:** `tests/test_purity.py` in each handler — runs the scanner; zero violations.

#### F05 — Purity check 2 passes
Every handler has at least one unit test invoking the function with a frozen state; any mutation raises. **Unit test:** `tests/test_handler_purity.py`.

### feishu_app handler (`handlers/feishu_app/`)

#### F06 — State
```python
@handler_state(actor_type="feishu_app_proxy", schema_version=1)
class FeishuAppState(BaseModel):
    model_config = {"frozen": True}
    app_id: str = ""
    bound_threads: frozenset[str] = frozenset()
```
**Unit test:** `tests/test_state.py` — defaults, equality, frozen.

#### F07 — `/new-thread <name>` triggers InvokeCommand
If `event.event_type == "msg_received"` and `event.args["content"]` starts with `/new-thread `, extract the thread name. If empty after prefix → return `(state, [])` (malformed, ignore). If already in `bound_threads` → return `(state, [])` (idempotent). Otherwise → return `(state.with_added_thread(name), [InvokeCommand("feishu-thread-session", {"thread_id": name})])`. **Unit test:** `tests/test_on_msg.py` — new thread triggers, duplicate idempotent, malformed ignored.

#### F08 — Regular messages route to bound thread
If `event.args.get("thread_id")` is present AND in `bound_threads`, emit `[Route(target=f"thread:{thread_id}", msg=event.args["content"])]`. Otherwise no routes (unknown thread). **Unit test:** bound thread routes; unknown thread silent.

#### F09 — Non-`msg_received` events ignored
Any other event type returns `(state, [])`. **Unit test:** `reaction_added` / arbitrary type ignored.

### feishu_thread handler (`handlers/feishu_thread/`)

#### F10 — State
```python
@handler_state(actor_type="feishu_thread_proxy", schema_version=1)
class FeishuThreadState(BaseModel):
    model_config = {"frozen": True}
    thread_id: str = ""
    dedup: frozenset[str] = frozenset()  # bounded; see F11
    ack_msg_id: str | None = None
```

#### F11 — Dedup bound
`dedup` is bounded to 1000 entries using `with_added_dedup(msg_id)` which, if the set is at limit, drops the oldest entry. Since `frozenset` is unordered, v0.1 uses a simple policy: when at cap, replace the entire set with a subset of the newest (tracked via an auxiliary `dedup_order: tuple[str, ...]`). **Unit test:** add 1001 → set size = 1000.

#### F12 — Inbound: ack + forward to tmux
`event.event_type == "feishu_msg_received"`. Check dedup. If already seen → `(state, [])`. Otherwise:
```
actions = [
  Emit(adapter="feishu-shared", action="react",
       args={"msg_id": msg_id, "emoji": "ack"}),
  Emit(adapter="cc_tmux", action="send_keys",
       args={"session_name": thread_id, "content": content}),
]
return state.with_added_dedup(msg_id), actions
```
**Unit test:** fresh msg → both emits; dup msg → no emits.

#### F13 — Outbound: tmux output → feishu send
`event.event_type == "cc_output"` → emit `[Emit(adapter="feishu-shared", action="send_message", args={"chat_id": <from state>, "content": event.args["text"]})]`. State carries the originating chat_id (stored on first message). **Unit test:** cc_output → one Emit; chat_id from state.

#### F14 — on_spawn initialisation
There is no `on_spawn` hook in v0.1 (the pure-function model has no lifecycle callback). Initial state comes from pattern `params` via pydantic default + explicit init in topology instantiation. **Unit test:** assert no callback interface needed.

### tmux_proxy handler (`handlers/tmux_proxy/`)

#### F15 — State
```python
@handler_state(actor_type="tmux_proxy", schema_version=1)
class TmuxProxyState(BaseModel):
    model_config = {"frozen": True}
    session_name: str = ""
```

#### F16 — Pass-through routing
The tmux_proxy actor exists mainly to connect thread-proxy to cc-proxy — its handler forwards most messages unchanged. Specifically, `event.event_type == "send_keys_request"` (from thread-proxy via Route) → `[Emit(adapter="cc_tmux", action="send_keys", args=event.args)]`. `event.event_type == "cc_output"` (from cc_tmux adapter) → `[Route(target=f"cc:{session_name}", msg=event.args)]`. **Unit test:** both directions.

### cc_session handler (`handlers/cc_session/`)

#### F17 — State
```python
@handler_state(actor_type="cc_proxy", schema_version=1)
class CcSessionState(BaseModel):
    model_config = {"frozen": True}
    session_name: str = ""
    parent_thread: str = ""   # for reverse routing
    pending_outputs: tuple[str, ...] = ()  # buffered outputs (rarely used)
```

#### F18 — Reverse-route cc_output to thread
`event.event_type == "cc_output"` → `[Route(target=f"thread:{parent_thread}", msg={"event_type": "cc_output", "args": event.args})]`. **Unit test:** cc_output → one Route.

#### F19 — Ignore unknown events
Any other event type → `(state, [])`. **Unit test:** arbitrary event ignored.

## Non-functional Requirements

- Every handler function executes in < 5 ms (well under the 5 000 ms RPC timeout)
- Purity: all four handlers pass purity checks 1 + 2
- No module-level mutable state (only `HANDLER_REGISTRY` inserts at import time)

## Dependencies

- PRD 02 (SDK) for decorators
- PRD 04 (adapters) must be installed before a handler's `Emit` can be validated against declared adapter action sets

## Unit-test matrix

| FR | Test file | Test name |
|---|---|---|
| F06 | `handlers/feishu_app/tests/test_state.py` | frozen / defaults |
| F07 | `handlers/feishu_app/tests/test_on_msg.py` | new_thread / duplicate / malformed |
| F08 | same | routes to bound |
| F09 | same | non-msg events |
| F10 | `handlers/feishu_thread/tests/test_state.py` | state |
| F11 | same | dedup bound |
| F12 | `handlers/feishu_thread/tests/test_on_msg.py` | inbound ack + forward |
| F13 | same | outbound send_message |
| F15 | `handlers/tmux_proxy/tests/test_state.py` | state |
| F16 | `handlers/tmux_proxy/tests/test_on_msg.py` | pass-through |
| F17 | `handlers/cc_session/tests/test_state.py` | state |
| F18 | `handlers/cc_session/tests/test_on_msg.py` | reverse route |
| F19 | same | unknown event |
| F03 | per-handler `tests/test_state_frozen.py` | frozen |
| F04 | per-handler `tests/test_purity.py` | lint clean |
| F05 | per-handler `tests/test_handler_purity.py` | frozen-state invocation |

## Acceptance

- [x] All 19 FRs have passing unit tests — 4 handlers × (state + on_msg), cross-cutting purity parametric in test_handlers_cross_cutting.py
- [x] Each handler installs via `esr handler install ./handlers/<name>/` + appears in `esr handler list` — covered by test_cli_install.py + test_handler_layout.py
- [x] Purity: zero violations per `esr-lint handlers/` — test_handlers_cross_cutting.py::test_handler_module_import_scan_clean
- [ ] Integration with PRDs 04 + 06: feishu-thread-session spawn chain — Phase 8 live run deferred

---

*End of PRD 05.*
