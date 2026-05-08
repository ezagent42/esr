# ESR Module Details

> Generated from `.artifacts/bootstrap/module-reports/*.json` by Skill 0 on 2026-04-21.
> Layer mapping:
> - Layer 1 (Elixir OTP runtime) = `runtime-core`, `runtime-subsystems`, `runtime-web`
> - Layer 2 (Python handlers, pure) = `handler-*`
> - Layer 3 (Python adapters, I/O) = `adapter-*`
> - Layer 4 (Python commands/patterns) = `py-sdk-core`, `patterns-roles-scenarios`
> - Cross-cutting infra = `py-cli`, `py-ipc`, `py-verify`, `scripts`

## py-sdk-core

**Path:** `py/src/esr/ + py/tests/ (core SDK)`

**Description:** Python SDK for ESR v0.1 — decorators/registries for handlers, adapters, commands; the pattern EDSL (node/port/compose/compile_to_yaml); frozen Action/Event/Directive dataclasses; esr:// URI parser; workspaces.yaml helpers.

**Test baseline:** exit=0, passed=149, failed=0, skipped=0

```
cd /home/yaosh/projects/esr/py && uv run pytest tests/test_actions.py tests/test_adapter.py tests/test_adapter_layout.py tests/test_command.py tests/test_command_compose.py tests/test_command_yaml.py tests/test_events.py tests/test_handler.py tests/test_handler_layout.py tests/test_optimizer_cse.py tests/test_optimizer_dead_node.py tests/test_package.py tests/test_pattern_compile_yaml.py tests/test_pattern_cycle_rejected.py tests/test_pattern_feishu_app_session.py tests/test_pattern_feishu_thread_session.py tests/test_pattern_param_lint.py tests/test_public_api.py tests/test_uri.py tests/test_workspaces.py -q
```


**Key interfaces:**
| Interface | Location | Description |
|---|---|---|
| `@handler(actor_type, name) / @handler_state(actor_type, schema_version)` | py/src/esr/handler.py:54 | Register pure handler function and its frozen pydantic state model into HANDLER_REGISTRY / STATE_REGISTRY (PRD 02 F04/F05/F06). |
| `@adapter(name, allowed_io) + AdapterConfig` | py/src/esr/adapter.py:53 | Register an adapter class (must have staticmethod factory) into ADAPTER_REGISTRY; AdapterConfig wraps config dict with read-only attribute access. |
| `@command / node / port / compose / compile_topology / compile_to_yaml` | py/src/esr/command.py:50 | Pattern EDSL and compile pipeline: `>>` edges, port.input/output, compose.serial, cycle/dead-node/param-lint checks, deterministic YAML emit (PRD 02 F |
| `Emit / Route / InvokeCommand (Action union)` | py/src/esr/actions.py:28 | The three handler-return action shapes, all frozen with MappingProxyType payloads (§4.4, PRD 02 F02). |
| `Event / Directive (+ Event.from_envelope)` | py/src/esr/events.py:20 | Frozen inbound/outbound message dataclasses; Event.from_envelope deserialises an IPC envelope (PRD 02 F03). |
| `EsrURI parse/build` | py/src/esr/uri.py:63 | Strict esr://[org@]host[:port]/<type>/<id>[?k=v] parser + builder matching the Elixir Esr.URI (PRD 02 F15). |
| `load_adapter_factory(name)` | py/src/esr/adapters.py:22 | Imports esr_<name> to trigger registration and returns the class's unwrapped factory callable (Phase 8a/8b). |
| `read_workspaces / write_workspace / remove_workspace` | py/src/esr/workspaces.py:34 | workspaces.yaml CRUD with schema_version=1 (spec §5.1). |

**Dependencies:** `pydantic (BaseModel for handler_state, frozen model enforcement)`, `PyYAML (yaml.safe_load / yaml.safe_dump for command YAML + workspaces.yaml)`, `stdlib: dataclasses, types.MappingProxyType, contextvars, contextlib, importlib, urllib.parse, pathlib, re, tomllib (tests), typing`

**User flows:**
- **Author a handler + state** (entry: `py/src/esr/handler.py:54`) — first step: `Define a frozen pydantic BaseModel (model_config={'frozen': True}) and decorate with @esr.handler_state(actor_type=..., schema_version=1).`
- **Register an adapter package** (entry: `py/src/esr/adapter.py:53`) — first step: `Create esr_<name>/__init__.py that exposes a class with @adapter(name=..., allowed_io={...}).`
- **Compose a pattern and emit deterministic YAML** (entry: `py/src/esr/command.py:335`) — first step: `Decorate a zero-arg function with @command('<name>').`
- **Parse / build esr:// URIs across the Python/Elixir boundary** (entry: `py/src/esr/uri.py:63`) — first step: `esr.uri.parse('esr://[org@]host[:port]/<type>/<id>[?params]') → EsrURI.`
- **Manage workspaces.yaml** (entry: `py/src/esr/workspaces.py:34`) — first step: `read_workspaces(path) → {name: Workspace}.`

**Notes:** Purity rules are documented in esr/adapter.py: the @adapter decorator only performs a shape check (staticmethod factory present) — pure-factory I/O enforcement is deferred to esr.verify.capability.scan_adapter driven by the CI `esr-lint adapters/` hook (reviewer S2). All public dataclasses (Emit/Route/InvokeCommand/Event/Directive/_Node/Topology/EsrURI/Workspace/CommandEntry/HandlerEntry/StateEntry/AdapterEntry) are frozen; dict payloads are wrapped in types.MappingProxyType so they are read-only and hashable. EDSL uses contextvars (_CURRENT ContextVar) so `node()`/`>>`/`port`/`compose` work only inside `_command_context` or `compile_topology`; calling them outside raises RuntimeError. Optimizer rules: dead-node elimination only triggers when any edge or depends_on exists (PRD 06 F05); CSE …

## py-cli

**Path:** `py/src/esr/cli`

**Description:** Click-based `esr` CLI entry point (PRD 07). Provides operator-facing commands for runtime control (use/status/drain/scenario), adapter + handler + command lifecycle (install/compile/show/run/stop/restart/list), live-actor introspection (actors/trace/telemetry), admin/debug (debug/deadletter), and workspace templates. Communicates with the Elixir Phoenix runtime through a short-lived Phoenix-channel RPC bridge (`runtime_bridge`). Pure offline ops (lint, list, compile) need no runtime; stateful ops require `esr use <host:port>` context.

**Test baseline:** exit=0, passed=90, failed=0, skipped=0

```
cd /home/yaosh/projects/esr/py && uv run pytest tests/test_cli_actors.py tests/test_cli_adapter_add.py tests/test_cli_cmd_compile.py tests/test_cli_cmd_install.py tests/test_cli_cmd_restart.py tests/test_cli_cmd_run.py tests/test_cli_cmd_show.py tests/test_cli_cmd_stop.py tests/test_cli_deadletter.py tests/test_cli_debug.py tests/test_cli_drain.py tests/test_cli_error_ux.py tests/test_cli_install.py tests/test_cli_lint.py tests/test_cli_list.py tests/test_cli_offline.py tests/test_cli_scenario.py tests/test_cli_scenario_exec.py tests/test_cli_status.py tests/test_cli_submit_roundtrip.py tests/test_cli_telemetry.py tests/test_cli_trace.py tests/test_cli_use.py tests/test_cli_workspace.py tests/test_cmd_run_output_format.py tests/test_runtime_bridge.py -q
```


**Key interfaces:**

- **cli_entry_point**: `binary`=esr, `click_root_group`=py/src/esr/cli/main.py:66 cli()

- **cli_commands**
  - `esr use [<host:port>]` — 
  - `esr status` — 
  - `esr scenario run <name> [--verbose]` — 
  - `esr adapters list` — 
  - `esr adapter add <instance> --type <T> [--k v ...]` — 
  - `esr adapter install <source>` — 
  - `esr adapter list` — 
  - `esr handler install <source>` — 

- **runtime_bridge**: `description`=Synchronous Phoenix-channel RPC — each `cli:<op>` , `public_api`=["call_runtime(*, topic, event='cli_call', payload, `internal`=['_call_runtime_async(topic, event, payload, url, , `error_semantics`={'connect_failure': 'Wrapped as RuntimeUnreachable, `reply_envelope`=Phoenix phx_reply of form {status: 'ok'|'error', r

- **cli_dispatch_topics**
  - `cli:run/<name> — _submit_cmd_run (main.py:692) → Elixir Registry.activate`
  - `cli:stop/<name> — _submit_cmd_stop (main.py:708) → Registry.deactivate`
  - `cli:trace — _submit_trace (main.py:734) → Telemetry.Buffer`
  - `cli:debug/<action> — _submit_debug (main.py:747) → DebugOps (replay/inject/pause/resume)`
  - `cli:drain — _submit_drain (main.py:755) → shutdown orchestrator`
  - `cli:telemetry/<pattern> — _stream_telemetry (main.py:765) → Telemetry subscription`
  - `cli:actors/<action> — _submit_actors (main.py:787) → ActorRegistry (list/tree/inspect/logs)`
  - `cli:deadletter/<action> — _submit_deadletter (main.py:796) → DeadLetter (list/retry/flush)`

- **config_surface**: `endpoint_context_file`=~/.esr/context (YAML: {endpoint: ws://HOST:PORT/ad, `env_override`=ESR_CONTEXT (takes precedence over file), `runtime_url_env`=ESR_HANDLER_HUB_URL (for cli → handler-hub RPC), `adapters_yaml`=~/.esrd/default/adapters.yaml (written by adapter_, `workspaces_yaml`=~/.esrd/default/workspaces.yaml (written by worksp

**Dependencies:**
- **external_python**: ['click — CLI framework (group/command decorators)', 'PyYAML (yaml) — context/artifact/adapters.yaml/workspaces.yaml parsing + emission', 'aiohttp — used by ChannelClient and in tests for fake Phoenix
- **internal_esr_modules**: ['esr.ipc.channel_client.ChannelClient — WebSocket Phoenix channel client', 'esr.ipc.url.discover_runtime_url — resolves handler-hub URL', 'esr.verify.capability.scan_adapter — capability allow-list l
- **target_runtime**: Elixir Phoenix (runtime_ex app) via WebSocket on /handler_hub/socket and /adapter_hub/socket

**User flows:**
- **** — first step: `esr use localhost:4001  (writes ~/.esr/context)`
- **** — first step: `esr adapter install adapters/feishu  (capability-scan)`
- **** — first step: `esr actors list  → find actor_id and pid`
- **** — first step: `esr drain --timeout 30s  → cli:drain RPC; reports drained / timeouts; exit non-zero if any topology timed out`
- **** — first step: `Author scenarios/<name>.yaml with setup/steps/teardown sections`
- **** — first step: `esr cmd compile feishu-app-session -o /tmp/x.yaml  (no network)`

**Notes:** ["All 90 tests pass in 5.48s against the current repo (exit 0). Two 'Unclosed client session' warnings surface from aiohttp test fixtures — they are benign warnings, not failures.", 'The CLI ↔ runtime bridge is strictly one-shot RPC over Phoenix channels (v2 protocol). The runtime_bridge module is only 77 lines: each call creates a ChannelClient, joins the target topic, issues a phx call, and closes. No persistent connection, no long-lived streams — even `telemetry subscribe` (main.py:1073) is currently a single-call snapshot with the noted comment that live streaming is Phase 8d work.', "The _submit_* helper family in main.py (lines 682–802) consistently unwraps Phoenix phx_reply envelopes: first peel `status == 'ok'` + `response`, then peel `data` where the Elixir dispatcher nests handle bodies. Verified by tests/test_cli_submit_roundtrip.py against a real aiohttp WebSocket fake.", "adapter add has a side effect (main.py:371) specifically for type='feishu' with an app_id: it auto-compiles patterns/feishu-app-session.py if no compiled artifact exists and submits cli:run/<name> via runtime_bridge — intended to auto-bind adapter:feishu/feishu-app:<app_id> so inbound bot-message polling reaches a PeerServer without an extra operator step. If esrd is unreachable, it logs a note instead of failing.", 'Two naming overlaps to note: `adapters` (plural group, line 276) lists configured instances from adapters.yaml; `adapter` (singular group, line 303) handles add/install/list of adapter types. Both groups are registered — `esr adapter list` and `esr adapters list` report different data.', 'Context file and endpoint URL are distinct concerns: `esr use` stores `ws://HOST:PORT/adapter_hub/socket`, while runtime_bridge talks to `/handler_hub/socket` via discover_runtime_url — adapter hub vs handler hub are two separate Phoenix endpoints on esrd.', "Scenario runner (main.py:136) executes each step's `command` via `subprocess.run(shell=True)`, which is an intentional spec-v2.1 choice for E2E scripting. Teardown is always-run best-effort; setup failure short-circuits without running steps; step failures continue to collect failures and still run teardown."]

## py-ipc

**Path:** `py/src/esr/ipc/`

**Description:** Python<->Elixir IPC layer. Provides (1) an aiohttp-backed Phoenix Channels v2 client with multi-topic multiplexing + auto-reconnect + bounded pending-push queue, (2) a typed envelope schema with builders for event/directive/directive_ack/handler_call/handler_reply (wire invariant: source must be an esr:// URI), (3) adapter_runner and handler_worker subprocess entry points (python -m esr.ipc.adapter_runner / handler_worker) that join topic `adapter:<name>/<instance>` or `handler:<module>/<worker_id>` and dispatch envelopes FIFO, (4) URL discovery that distinguishes the /adapter_hub and /handler_hub Phoenix sockets.

**Test baseline:** exit=?, passed=75, failed=0, skipped=1

```
cd py && uv run pytest tests/test_adapter_loader.py tests/test_adapter_manifest.py tests/test_adapter_runner.py tests/test_adapter_runner_main.py tests/test_adapter_runner_run.py tests/test_channel_client.py tests/test_channel_client_call.py tests/test_channel_pusher.py tests/test_envelope.py tests/test_handler_worker.py tests/test_handler_worker_main.py tests/test_handler_worker_run.py tests/test_ipc_integration.py tests/test_url_discovery.py -q
```


**Key interfaces:**

- **envelope_schema**: `common_fields`={'kind': 'duplicate of `type` (legacy; set by buil, `payloads`={'event': '{event_type: str, args: dict} -- make_e, `action_discriminators`={'emit': '{type: emit, adapter, action, args} -- e

- **phoenix_channel_client**: `class`=ChannelClient(url, auto_reconnect=False, backoff_s, `wire_format`=Phoenix v2 array frame `[join_ref, ref, topic, eve, `methods`={'connect()': 'opens aiohttp WS, starts _read_loop, `reconnect`=on auto_reconnect=True: exponential backoff (1,2,4

- **channel_pusher**: `class`=ChannelPusher(client, topic, source_uri) -- channe, `role`=adapts ChannelClient.push to the AdapterPusher pro

- **adapter_runner**: `process_directive(adapter, payload)`=calls adapter.on_directive(action, args); wraps su, `directive_loop(adapter, queue, pusher)`=drains queue FIFO; None=sentinel; pushes directive, `event_loop(adapter, pusher)`=iterates adapter.emit_events() async gen, wraps ea, `run_with_client(adapter, client, topic)`=connects, joins topic with _on_frame that filters , `run(adapter_name, instance_id, config, url)`=loads factory via esr.adapters.load_adapter_factor

- **handler_worker**: `process_handler_call(payload)`=pure dispatcher -- resolves HANDLER_REGISTRY[paylo, `_dump_state`=serialises pydantic model and coerces frozenset/se, `run_with_client(client, topic)`=connects, joins topic with _on_frame filtering kin, `run(handler_module, worker_id, url)`=importlib.import_module(`esr_handler_<pkg>.on_msg`, `main/CLI`=python -m esr.ipc.handler_worker --module <dotted>

- **url_discovery**: `discover_runtime_url(override, kind='adapter'|'handler'|None)`=priority: override > ESR_{ADAPTER|HANDLER}_HUB_URL, `defaults`=ws://localhost:4001/adapter_hub/socket/websocket?v

- **topic_naming**: `adapter`=`adapter:<adapter_name>/<instance_id>` -- adapter_, `handler`=`handler:<handler_module>/<worker_id>` -- handler_, `source_uri_convention`=`esr://localhost/<topic>` for outgoing envelopes (, `phoenix_event_name`=All envelopes are pushed under Phoenix event name 

- **subprocess_launch**: `adapter_runner`=Invoked as `uv run --project py python -m esr.ipc., `handler_worker`=Invoked as `python -m esr.ipc.handler_worker --mod

**Dependencies:**
- **external**: ['aiohttp (WebSocket client; channel_client.py:43)', 'pydantic (handler state models; handler_worker.py and tests)']
- **internal**: ['esr.actions (Action/Emit/Route/InvokeCommand ADT -- envelope.py:26)', 'esr.events (Event dataclass -- handler_worker.py:30)', 'esr.handler (HANDLER_REGISTRY, STATE_REGISTRY -- handler_worker.py:31)'
- **elixir_counterparts**: ['runtime/lib/esr/ipc/envelope.ex (PRD 01 F09-F12; constants kept in lock-step per envelope.py:16-17)', 'Phoenix channels AdapterHub/HandlerHub (routes /adapter_hub/socket, /handler_hub/socket)']

**User flows:**
- **adapter directive round-trip (runtime -> adapter)** — first step: `Elixir runtime pushes envelope {kind:directive, id:d-..., source:esr://..., payload:{action,args}} on topic adapter:<name>/<instance>`
- **adapter event emission (adapter -> runtime)** — first step: `Adapter implements async generator emit_events() yielding {event_type, args}`
- **handler call round-trip (runtime -> handler worker)** — first step: `HandlerRouter pushes envelope {kind:handler_call, id:h-..., payload:{handler, state, event}} on handler:<module>/<worker>`
- **disconnect/reconnect with pending push preservation** — first step: `WS closes; _read_loop sets _is_disconnected=True and schedules _reconnect_loop (channel_client.py:232-235)`

**Notes:** ['Envelope has both `kind` and `type` set to the same discriminator -- the `kind` field is what _on_frame dispatches on (adapter_runner.py:136, handler_worker.py:154); presumably legacy/redundant but tests assert both.', 'The Phoenix event name for all application envelopes is the literal string `envelope`; phx_reply / phx_join are reserved for protocol frames (channel_client.py:214, 137).', 'Reviewer C1 fix: split adapter_hub vs handler_hub URLs; legacy ESR_RUNTIME_URL remains an adapter-only alias (url.py documentation + test_url_discovery.py).', 'Reviewer S7 fix: _read_loop wraps frame JSON decode + arity unpack in try/except so one bad frame does not tear down the socket (channel_client.py:207-212; covered by test_channel_client_tolerates_malformed_frames).', 'Reviewer S3 fix: process_handler_call catches KeyError/TypeError/AttributeError on envelope access and surfaces MalformedEnvelope instead of raising (handler_worker.py:43-51).', 'PRD 02 F05 / Reviewer C2 fix: state dicts carry `_schema_version`; mismatch returns SchemaVersionMismatch error; replies stamp the registered version on new_state (handler_worker.py:64-95).', 'Frozenset/set values in pydantic state are coerced to sorted lists before JSON serialisation (handler_worker.py:124-134) -- Phoenix JSON encoder does not accept sets.', 'adapter_runner.run imports esr.adapters at runtime to avoid circular imports and to defer optional adapter loading.', 'handler_worker.run module-import heuristic: tries `esr_handler_<first_segment>.on_msg` first, falls back to raw dotted path for test shims (handler_worker.py:190-195).', 'The live-runtime integration test (test_ipc_integration.py) is the only skipped test; gated on ESR_E2E_RUNTIME=1 with a running Phoenix server on ws://localhost:4001.']

## py-verify

**Path:** ``

**Description:** 

**Test baseline:** exit=?, passed=?, failed=?, skipped=?


## adapter-feishu

**Path:** `adapters/feishu`

**Description:** ESR v0.1 Feishu (Lark) adapter. Integrates Feishu for messaging — registers a FeishuAdapter in the ESR adapter registry at import time, accepts directives for message posting / reactions / pins / card sending / file download, and emits inbound messages as msg_received events. Supports a dual live/mock path: when AdapterConfig.base_url points at 127.0.0.1/localhost the adapter talks to mock_feishu over HTTP + WS; otherwise it uses lark_oapi's REST client and a WebSocket listener with a poll-fallback for bot-self messages. Factory is pure (PRD 04 F02) — no network I/O until first client() call. Includes exponential-backoff rate-limit retry (F15), per-msg_type content parsers (F13), and WS-event shape normalization for handler consumption.

**Test baseline:** exit=?, passed=40, failed=0, skipped=?

```
cd /home/yaosh/projects/esr/py && uv run pytest ../adapters/feishu/tests/ -q
```


**Key interfaces:**

- **manifest**: `name`=feishu, `version`=0.1.0, `module`=esr_feishu.adapter, `entry`=FeishuAdapter, `allowed_io`={'lark_oapi': '*', 'aiohttp': '*', 'http': ['open.

- **public_class**: `FeishuAdapter`={'path': 'esr_feishu.adapter', 'constructor': '__i

- **directives_accepted**
  - `?` — 
  - `?` — 
  - `?` — 
  - `?` — 
  - `?` — 
  - `?` — 

- **events_emitted**
  - `?` — 
  - `?` — 

- **parsers**: `module`=esr_feishu.parsers, `parse_content_supports`=['text', 'post', 'image', 'file', 'audio', 'media', `fallback`=[<msg_type> message], `parse_ws_event_supports`=['P2ImMessageReceiveV1 -> msg_received', 'P2ImMess

- **rate_limit**: `backoff_schedule_seconds`=[1.0, 2.0, 4.0, 8.0, 16.0, 30.0], `retry_deadline_seconds`=30.0, `trigger`=lark response code == 429, `on_deadline`={ok: false, error: 'timeout'}

**Dependencies:**
- **python_version**: >=3.11
- **runtime**: ['esr (editable, ../../py)', 'lark-oapi>=1.0', 'aiohttp>=3.9']
- **esr_symbols_used**: ['esr.adapter.adapter (decorator)', 'esr.adapter.AdapterConfig', 'esr.adapter.ADAPTER_REGISTRY', 'esr.verify.capability.scan_adapter']
- **test_only**: ['pytest (asyncio_mode=auto)', 'scripts/mock_feishu.MockFeishu']

**User flows:**
- **Registration at import**
- **Outbound send_message (live)**
- **Outbound send_message (mock/scenario)**
- **Inbound event streaming (live)**
- **Inbound event streaming (mock)**
- **File download**
- **Rate-limit retry**
- **Capability scan**

**Notes:** ["esr.toml manifest: allows lark_oapi (*), aiohttp (*), http -> open.feishu.cn, urllib -> 127.0.0.1+localhost. Matches the @adapter decorator's allowed_io in code.", 'Factory purity is a hard contract (PRD 04 F02) — FeishuAdapter.factory stores config only; lark_oapi.Client is built on first client() call inside directive/event paths. test_factory_purity monkeypatches socket.create_connection to assert no I/O happens.', "Directive set (6 total): send_message, react, send_card, pin, unpin (all under _with_ratelimit_retry) + download_file (no retry wrapper — synchronous, failure is surfaced directly). Unknown actions return {ok: false, error: 'unknown action: <name>'} instead of raising.", 'Event emission set (2 shapes): msg_received (live WS + mock WS + bot-self poll, adapter-symmetric across paths) and reaction_added (shape is defined by parse_ws_event but live emit_events currently only wires p2_im_message_receive_v1 — reaction events are not yet emitted from the WS loop).', 'Content-text unwrapping happens at the adapter boundary: raw {"text": "..."} JSON is parsed into plain text for args.content; the raw JSON string is preserved on args.raw_content for diagnostics. Handlers can thus pattern-match on literal prefixes like \'/new-thread\'.', 'Fixtures (live-capture/*.json) are real Feishu wire frames, all event_type=im.message.receive_v1 under schema 2.0, app_id cli_a9564804f1789cc9. Three variants: text_message (message_type=text), thread_reply (text with root_id+parent_id set), card_interaction (message_type=interactive carrying the Tool Activity card JSON).', "Two WS paths exist because Lark's im.message.receive_v1 does NOT fire for messages the bot itself posts via REST. The _poll_chat_messages fallback bridges that gap for final_gate.sh --live, polling im.v1.message.list every 2s and deduping by message_id with a bootstrap pass that marks historical messages as seen.", "lark_oapi.ws.Client.start() is synchronous and grabs the asyncio event loop at import time; the adapter patches lark_oapi.ws.client.loop to a fresh thread-local loop in the executor so it doesn't collide with the caller's running loop.", "Parsers are pure functions (no runtime fetches, in contrast with the ported cc-openclaw version) — parser exceptions are caught and return '[<msg_type> message — parse failed]' so a malformed payload can't kill the event stream.", 'Tests use stub lark response objects rather than hitting live Lark; test_emit_events spins up scripts/mock_feishu.MockFeishu to exercise the mock-WS path end-to-end. test_client is the only suite that exercises the real lark_oapi.Client.builder() (accounting for the 90s test-suite duration — the build path is slow).']

## adapter-cc-tmux

**Path:** ``

**Description:** 

**Test baseline:** exit=?, passed=?, failed=?, skipped=?


**Dependencies:**
- **runtime**: ['esr (editable path ../../py)']
- **external_binary**: tmux

## adapter-cc-mcp

**Path:** ``

**Description:** 

**Test baseline:** exit=0, passed=7, failed=0, skipped=0

```
cd /home/yaosh/projects/esr/adapters/cc_mcp && PYTHONPATH=src uv run --with mcp --with anyio --with aiohttp --with websockets --with pytest --with pytest-asyncio pytest tests/ -q
```


**Key interfaces:**
| Interface | Location | Description |
|---|---|---|
| `python -m esr_cc_mcp.channel (main entrypoint)` | adapters/cc_mcp/src/esr_cc_mcp/channel.py:171 | Invoked by CC as an MCP stdio server. Reads ESR_ESRD_URL, ESR_SESSION_ID, ESR_WORKSPACE, ESR_CHAT_IDS, ESR_ROLE. Exits 0 on KeyboardInterrupt or sessi |
| `MCP list_tools / call_tool handlers` | adapters/cc_mcp/src/esr_cc_mcp/channel.py:127 | Server('esr-channel') exposes list_tool_schemas(role) and proxies every call_tool(name, args) to _invoke_tool, which sends tool_invoke envelope over W |
| `list_tool_schemas(role) -> [Tool]` | adapters/cc_mcp/src/esr_cc_mcp/tools.py:78 | Returns [reply, react, send_file] by default; +[_echo] when role='diagnostic'. API-compatible with cc-openclaw's openclaw-channel. |
| `EsrWSClient(url, session_id, workspace, chats)` | adapters/cc_mcp/src/esr_cc_mcp/ws_client.py:38 | Phoenix v2 WS client with connect_and_run(on_envelope) reconnect loop and push(envelope) send. Topic 'cli:channel/{session_id}', vsn=2.0.0 endpoint /c |
| `compute_backoff(attempt, rng=random.random)` | adapters/cc_mcp/src/esr_cc_mcp/ws_client.py:25 | Deterministic-testable jittered exponential backoff: min(30, 2^attempt) * (0.5 + rng()). |

**Dependencies:** `mcp>=1.0.0 (Server, InitializationOptions, NotificationOptions, stdio_server, Tool, TextContent)`, `anyio>=4.0 (task group, anyio.run)`, `aiohttp>=3.9 (ClientSession + ws_connect for Phoenix WS)`, `websockets>=12.0 (declared dep; not directly imported in the reviewed modules)`, `stdlib: asyncio, json, logging, os, sys, uuid, random, typing, collections.abc`

**User flows:**
- **CC author sends a Feishu reply via reply tool** (entry: `adapters/cc_mcp/src/esr_cc_mcp/channel.py:89`) — first step: `CC (running the esr-channel MCP server) calls tool 'reply' with {chat_id:'oc_...', text:'hi'}.`
- **Inbound Feishu message appears in CC conversation** (entry: `adapters/cc_mcp/src/esr_cc_mcp/channel.py:62`) — first step: `Feishu webhook → feishu adapter → esrd routes to this session as {kind:'notification', source:'feishu', chat_id, message_id, user, ts, content}.`
- **final_gate --live v2 deterministic loop via _echo** (entry: `adapters/cc_mcp/src/esr_cc_mcp/tools.py:63`) — first step: `Launch esr-channel with ESR_ROLE=diagnostic — list_tool_schemas now includes _echo.`
- **esrd restart / reconnect** (entry: `adapters/cc_mcp/src/esr_cc_mcp/ws_client.py:66`) — first step: `WS closes (esrd restart or network blip).`

**Notes:** This adapter is declared with kind='adapter' in esr.toml (allowed_io mcp=*, websocket=*, http=[]) but unlike cc_tmux it does not register via @esr.adapter / AdapterConfig in the Python SDK's ADAPTER_REGISTRY — it is a standalone MCP stdio process that CC spawns per session (entry `python -m esr_cc_mcp.channel`). Identity comes from env (ESR_ESRD_URL, ESR_SESSION_ID, ESR_WORKSPACE, ESR_CHAT_IDS, ESR_ROLE). All module state (_pending futures, _ws, _mcp_server) is module-global — safe because each CC session spawns a fresh process. Phoenix v2 framing: array frames [join_ref, ref, topic, event, payload]; topic 'cli:channel/<session_id>'; vsn=2.0.0 endpoint. Reconnect is infinite with min(30, 2^attempt)*(0.5+rng()) jitter; only CancelledError (propagated when CC stdio EOFs and the anyio task gr …

## handler-feishu-app

**Path:** `handlers/feishu_app/ (pure-python handler package)`

**Description:** Pure-Python handler package `esr_handler_feishu_app` for actor_type=feishu_app_proxy. Receives feishu adapter msg_received events from the Elixir runtime, maintains a frozen pydantic FeishuAppState, and returns (new_state, [Action]) — routing chat messages to bound threads, instantiating new thread sub-topologies via InvokeCommand, or dropping non-msg events. PRD 05 F06/F07/F08/F09, spec v0.2 §3.3.

**Test baseline:** exit=0, passed=12, failed=0, skipped=0

```
cd /home/yaosh/projects/esr/py && uv run pytest ../handlers/feishu_app/tests/ -q
```


**Key interfaces:**
| Interface | Location | Description |
|---|---|---|
| `FeishuAppState (handler state model)` | handlers/feishu_app/src/esr_handler_feishu_app/state.py:9 | Frozen pydantic BaseModel registered via @handler_state(actor_type='feishu_app_proxy', schema_version=1). Persisted per-actor state; fluent with_* met |
| `on_msg (handler entrypoint)` | handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py:20 | @handler(actor_type='feishu_app_proxy', name='on_msg'). Pure function (FeishuAppState, Event) -> (FeishuAppState, list[Action]). Returned actions are  |

**Dependencies:** `esr (editable path to py/) — imports Action, Event, InvokeCommand, Route, handler, handler_state`, `pydantic (BaseModel with model_config frozen=True) — provided transitively via esr`, `stdlib only (no I/O, no network, no filesystem, no os, no subprocess, no time, no random)`

**User flows:**
- **User starts a new thread session via /new-session** (entry: `handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py:60`) — first step: `Feishu user sends '/new-session <workspace> tag=<tag>' in a chat (or legacy '/new-thread <tag>').`
- **User addresses a specific thread via @<tag>** (entry: `handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py:106`) — first step: `User sends '@<tag> <body>' in the chat.`
- **Plain chat message routed to the active thread** (entry: `handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py:52`) — first step: `User sends a message without a prefix.`
- **Non-msg events are dropped** (entry: `handlers/feishu_app/src/esr_handler_feishu_app/on_msg.py:23`) — first step: `Events with event_type != 'msg_received' (e.g. reaction_added, card_action) return (state, []) with identity-preserved state.`

**Notes:** PURITY: verified — on_msg.py imports only `from __future__ import annotations`, `from esr import Action, Event, InvokeCommand, Route, handler` and its own state module; state.py imports only pydantic.BaseModel + esr.handler_state. No os/io/subprocess/socket/time/random/requests imports; no side effects; all state mutations go through pydantic model_copy (frozen=True enforced). manifest declares allowed_imports=[] consistent with the empty import surface. ACTION SHAPES EMITTED: (1) InvokeCommand('feishu-thread-session', {thread_id, chat_id, workspace, tag}) for /new-session and legacy /new-thread; (2) Route(target='thread:<tag>', msg={event_type, args}) for @-addressed and fallback routes; (3) Emit is NEVER returned by this handler — outbound feishu messages are the Elixir/thread handler's  …

## handler-feishu-thread

**Path:** `handlers/feishu_thread/`

**Description:** ESR v0.2 thread-scoped Feishu handler. One actor per Feishu thread bound to a CC session: dedups inbound msg_ids, captures chat_id on first inbound, notifies the esr-channel session on msg_received (replacing the v0.1 tmux send-keys path), and relays cc_output back to Feishu as send_message. Pure function — no on_spawn lifecycle hook (PRD 05 F14).

**Test baseline:** exit=0, passed=11, failed=0, skipped=0

```
cd /home/yaosh/projects/esr/py && uv run pytest ../handlers/feishu_thread/tests/ -q
```


**Key interfaces:**
| Interface | Location | Description |
|---|---|---|
| `on_msg(state: FeishuThreadState, event: Event) -> (FeishuThreadState, list[Action])` | handlers/feishu_thread/src/esr_handler_feishu_thread/on_msg.py:20 | Registered handler for actor_type='feishu_thread_proxy'. Handled event_types: 'msg_received' (from feishu adapter), 'cc_output' (from cc_tmux adapter) |
| `FeishuThreadState` | handlers/feishu_thread/src/esr_handler_feishu_thread/state.py:27 | Frozen pydantic state model for a feishu_thread_proxy actor. Fields: thread_id, chat_id, dedup (frozenset capped at 1000), dedup_order (FIFO tuple for |

**Dependencies:** `esr (core SDK: @handler, @handler_state, Event, Action, Emit)`, `pydantic (frozen BaseModel for state)`, `stdlib: __future__.annotations`

**User flows:**
- **Inbound Feishu message → notify CC session (v0.2 §3.3 primary path)** (entry: `handlers/feishu_thread/src/esr_handler_feishu_thread/on_msg.py:30`) — first step: `Feishu adapter receives a webhook and emits Event(event_type='msg_received', args={message_id, chat_id, sender_id, content}).`
- **CC output → relay to Feishu chat (PRD 05 F13)** (entry: `handlers/feishu_thread/src/esr_handler_feishu_thread/on_msg.py:58`) — first step: `cc_tmux adapter captures CC stdout and emits Event(event_type='cc_output', args={text, session}).`

**Notes:** v0.2 rewrite (commit context, on_msg.py docstring): v0.1 matched a non-existent 'feishu_msg_received' event and emitted tmux send-keys; both were dead code because the adapter actually emits 'msg_received'. The rewrite aligns the event name and switches the primary inbound path to the synthetic 'esr-channel' adapter + notify_session action that PeerServer resolves via SessionRegistry. The outbound cc_output→send_message branch is retained for the scenario mock path. Difference from handler-feishu-app (app-scoped): feishu_app handles whole-app lifecycle events (bot-join, app-level routing, spawning thread actors) while feishu_thread handles exactly one bound (thread_id ↔ chat_id ↔ CC session) conversation — it owns per-thread dedup and the chat_id learned at first inbound, and never spawns  …

## handler-cc-session

**Path:** ``

**Description:** 

**Test baseline:** exit=?, passed=?, failed=?, skipped=?


**Dependencies:**
- **runtime**: ['esr (py/, editable)']
- **imports_used**: ['esr.Action', 'esr.Event', 'esr.Route', 'esr.handler', 'esr.handler_state', 'pydantic.BaseModel']

## handler-tmux-proxy

**Path:** ``

**Description:** 

**Test baseline:** exit=?, passed=?, failed=?, skipped=?


**Dependencies:**
- **runtime**: ['esr (editable path ../../py)']
- **sdk_symbols**: ['Action', 'Emit', 'Event', 'Route', 'handler', 'handler_state']
- **allowed_imports_manifest**: []

## patterns-roles-scenarios

**Path:** `patterns/ + roles/ + scenarios/`

**Description:** Declarative artifacts module consumed by the ESR runtime/CLI. Three sub-directories: (1) patterns/*.py — Python EDSL topology definitions (esr.command/node decorators) that compile to YAML via `esr cmd compile`; each pattern is an @command-decorated function whose body builds a DAG of node(...) calls chained via >> to express depends_on edges. (2) roles/<name>/{CLAUDE.md,settings.json} — Claude-Code role packs attached to a tmux cc_session at spawn; `esr workspace add --role <name>` copies the CLAUDE.md + settings.json into the session's workspace so a new cc_proxy/cc_session picks them up on init. (3) scenarios/*.yaml — end-to-end scenario manifests executed by `esr scenario run`, with setup/steps/teardown arrays whose each entry is a shell command + expect_exit + expect_stdout_match regex; driven by final_gate.sh --mock as gate #4. No module-local tests — the patterns are covered indirectly by py/tests/test_pattern_*.py in py-sdk-core.

**Test baseline:** exit=None, passed=None, failed=None, skipped=None

```
no own tests; covered indirectly by py-sdk-core test_pattern_*.py
```


**Key interfaces:**

- **patterns**: `feishu-app-session`={'prd': 'PRD 06 F01 (v0.2)', 'semantics': 'Singlet, `feishu-thread-session`={'prd': 'PRD 06 F02', 'semantics': "Per-thread top

- **roles**: `dev`={'path': 'roles/dev/', 'claude_md': 'Developer-ass, `diagnostic`={'path': 'roles/diagnostic/', 'claude_md': 'Diagno

- **scenarios**: `e2e-esr-channel`={'path': 'scenarios/e2e-esr-channel.yaml', 'mode':, `e2e-feishu-cc`={'path': 'scenarios/e2e-feishu-cc.yaml', 'mode': '

- **compile_target**: `description`=Patterns compile to YAML consumed by `esr cmd run , `compile_entry`=esr cmd compile <name> -o <out.yaml> (py/src/esr/c

- **role_activation_path**: `esr workspace add <name> --role R` (py/src/esr/cli/main.py:1216 workspace_add) writes ~/.esrd/default/workspaces.yaml with a role pointer; cc_tmux init_directive's env.ESR_WORKSPACE=<name> hands it t

**Dependencies:**
- **external_python**: []
- **internal_esr_modules_used_by_patterns**: ['esr.command (@command decorator) — from `esr import command, node`', 'esr.node (node() constructor + >> operator for depends_on edges)']
- **adapter_handlers_referenced_by_patterns**: ['feishu (adapter)', 'cc_tmux (adapter)', 'feishu_app.on_msg (handler — called by feishu-app-session)', 'feishu_thread.on_msg (handler — called by feishu-thread-session thread node)', 'tmux_proxy.on_m
- **mcp_tools_used_by_roles**: ['mcp__esr-channel__reply', 'mcp__esr-channel__react', 'mcp__esr-channel__send_file', 'mcp__esr-channel___echo (diagnostic role only)']
- **scenario_runtime_requirements**: ['esrd daemon (runtime_ex app) on :4001', 'scripts/mock_feishu.py on :8101 (mock Feishu OpenAPI)', 'scripts/spawn_scenario_workers.sh (pre-spawns adapter + handler workers)', 'scripts/mock_mcp_ctl.py 
- **consumer_modules**: ['py/src/esr/cli/main.py:136 scenario_run — runs *.yaml scenarios', 'py/src/esr/cli/main.py:646 cmd_compile — compiles patterns/*.py → YAML', 'py/src/esr/cli/main.py:1216 workspace_add --role — binds 

**User flows:**
- **** — first step: `Write patterns/my-pattern.py with @command decorator + node(...) chain`
- **** — first step: `Place CLAUDE.md + settings.json under roles/<name>/`
- **** — first step: `final_gate.sh --mock  OR  esr scenario run e2e-esr-channel`
- **** — first step: `Pre-seeded workspace esr-dev --role diagnostic (scenario setup #7)`

**Notes:** ["Patterns use a tiny Python EDSL (from `esr import command, node`): @command('name') registers the function in esr.command.COMMAND_REGISTRY, node(id=..., actor_type=..., adapter=..., handler=..., params=..., depends_on=..., init_directive=...) constructs topology nodes, and the `>>` operator (returning the RHS) chains depends_on relationships. Template vars like {{app_id}} and {{thread_id}} stay as literals in the compiled YAML and are resolved at submit time from --param k=v flags.", "feishu-app-session is singleton (one per app_id). feishu-thread-session is parameterized per thread_id with chat_id/tag/workspace params. The tmux init_directive's env.ESR_WORKSPACE=='{{workspace}}' is the mechanism that hands the role's CLAUDE.md + settings.json to the newly-spawned cc session via scripts/esr-cc.sh.", 'The thread >> tmux >> cc chain guarantees correct startup order: thread actor starts first (it validates params + registers the chat binding), then tmux runs init_directive new_session (creates the tmux shell + launches scripts/esr-cc.sh), and only after tmux reports success does cc_proxy bind to the live cc_session process. Rollback on init_directive failure is handled by the Topology Instantiator (PRD 01 F13b).', "Roles are deliberately minimal: a markdown file (system prompt / rules) + a JSON MCP permission allow-list. The diagnostic role's _echo tool is intentionally kept out of the dev allow-list — dev sessions must NOT be able to short-circuit human reasoning via _echo.", "diagnostic CLAUDE.md rule #1 explicitly says 'Do NOT think, do not explain, do not call reply directly' — the _echo tool handles the reply itself with the synthetic nonce. This is critical for final_gate.sh --live's transit-latency probe to be reproducible.", "Both scenarios embed a fixed sig-B regex 'actor_id=(thread|tmux|cc|feishu-app):[a-z0-9-]+' in every step that matters — this is the spec-v2.1 LG-1 'log-grep' signature that the gate script cannot tamper with unless it also tampers with runtime output. e2e-feishu-cc additionally tests sig-A (BEAM pid shape <0.N.M>) in its C step.", 'e2e-esr-channel is the v0.2 scenario (7 steps), exercising the new MCP channel stack (ChannelSocket + ChannelChannel + SessionRegistry + cc_mcp bridge + /new-session command + @-addressing + session_killed broadcast). e2e-feishu-cc is the v0.1 legacy scenario (8 steps), exercising the original feishu-thread-session topology without the MCP channel layer.', "Both scenarios' setup sections kill stale mock_feishu instances before starting (e2e-esr-channel uses `pkill -f`, e2e-feishu-cc does not — relying on pidfile) — this re-run idempotency is important because final_gate.sh --mock may re-invoke on CI.", 'Module has zero module-local test files; coverage is in py-sdk-core under py/tests/test_pattern_*.py (notably test_pattern_feishu_thread_session.py and test_pattern_feishu_app_session.py) which import these .py files as modules and assert on the compiled topology shape. Scenarios are executed by py/tests/test_cli_scenario_exec.py against a fake runtime.']

## scripts

**Path:** ``

**Description:** 

**Test baseline:** exit=?, passed=?, failed=?, skipped=?


## runtime-core

**Path:** ``

**Description:** 

**Test baseline:** exit=?, passed=?, failed=?, skipped=?


## runtime-subsystems

**Path:** `runtime/lib/esr/{adapter_hub,handler_router,persistence,telemetry,topology,workspaces}/ + runtime/test/esr/<same>/`

**Description:** Elixir/OTP subsystems under Esr.Runtime: AdapterHub (adapter-topic↔actor binding), HandlerRouter (Phoenix-channel dispatch to Python handler workers), Topology Instantiator/Registry (YAML artifact → running PeerServers), ETS-backed Persistence with disk checkpointing, Telemetry buffer+attach, and the Workspaces registry cache (PRD 01 F08/F11/F13/F14/F15/F16/F18, spec §3.1/3.3/3.4/3.5/3.6).

**Test baseline:** exit=0, passed=56, failed=0, skipped=0

```
cd /home/yaosh/projects/esr/runtime && MIX_ENV=test mix test test/esr/adapter_hub/ test/esr/handler_router/ test/esr/persistence/ test/esr/telemetry/ test/esr/topology/ --max-failures 0
```


**Key interfaces:**
| Interface | Location | Description |
|---|---|---|
| `Esr.AdapterHub.Registry.{bind,unbind,lookup,list}` | runtime/lib/esr/adapter_hub/registry.ex:38 | Topic (adapter:<name>/<instance_id>) ↔ actor_id binding; auto-GCs on actor pid DOWN. |
| `Esr.HandlerRouter.call/3` | runtime/lib/esr/handler_router.ex:30 | Synchronously dispatch a handler_call envelope to handler:<module>/default and await handler_reply (default 5s). |
| `Esr.Persistence.Ets.{put,get,delete,clear,save_to_disk,load_from_disk}` | runtime/lib/esr/persistence/ets.ex:36 | Actor-state CRUD + atomic disk checkpoint (tmp+rename) + boot rehydrate (Track G-4). |
| `Esr.Telemetry.Buffer.{record,query}` | runtime/lib/esr/telemetry/buffer.ex:41 | Append + time-window select over ETS :ordered_set; O(1) write, no GenServer hop. |
| `Esr.Telemetry.Attach.attach/1` | runtime/lib/esr/telemetry/attach.ex:48 | Attach bounded [:esr, _, _] handler (20 events) into a named Buffer at boot. |
| `Esr.Topology.Instantiator.instantiate/3` | runtime/lib/esr/topology/instantiator.ex:40 | Idempotent YAML→actors: validate → toposort → spawn+bind+init_directive → register+telemetry. |
| `Esr.Topology.Registry.{register,lookup,list_all,put_artifact,get_artifact,deactivate}` | runtime/lib/esr/topology/registry.ex:42 | Handle + artifact ETS registry; atomic insert_new; deactivate fires reverse-order stop cascade (F14). |
| `Esr.Resource.Workspace.Registry.{get,list,put,load_from_file}` | runtime/lib/esr/workspaces/registry.ex:23 | In-memory workspaces.yaml cache keyed by workspace name. |

**Dependencies:** `:telemetry + :telemetry_registry (event bus for F15/F16)`, `Phoenix.PubSub + Phoenix.Channel via EsrWeb.Endpoint (Handler/Adapter channels + reply pubsub)`, `YamlElixir (parsing workspaces.yaml, adapters.yaml, compiled command YAML)`, `stdlib: :ets, :erlang.term_to_binary/1, Process.monitor/1, GenServer, Supervisor, Task`, `Cross-module: Esr.Entity.Registry (bind→pid), Esr.Entity.Supervisor (start/stop_peer), Esr.WorkerSupervisor (ensure_handler/adapter Python subprocesses), EsrWeb.Endpoint (broadcast)`

**User flows:**
- **AdapterHub: Python adapter subprocess registers its topic** (entry: `runtime/lib/esr/adapter_hub/registry.ex:38`) — first step: `Topology.Instantiator.spawn_in_order calls bind_adapter/1 → HubRegistry.bind("adapter:<name>/<instance_id>", actor_id).`
- **HandlerRouter: PeerServer dispatches to a Python handler worker** (entry: `runtime/lib/esr/handler_router.ex:30`) — first step: `PeerServer calls Esr.HandlerRouter.call(handler_module, payload, timeout).`
- **Topology.Instantiator: compiled YAML → live running actors** (entry: `runtime/lib/esr/topology/instantiator.ex:40`) — first step: `Esr.Topology.Instantiator.instantiate(artifact, params) — artifact comes from Python compile_to_yaml; early-exits if TopoRegistry.lookup(name, params) already has a handle (idempotency).`
- **Topology.Registry: lifecycle of a topology instance** (entry: `runtime/lib/esr/topology/registry.ex:90`) — first step: `start: Instantiator calls Registry.register(name, params, peer_ids) → atomic :ets.insert_new keyed by (name, sort(params)); duplicate returns the existing Handle (S7 no-TOCTOU).`
- **Persistence.Ets: restart-survival checkpoint cycle** (entry: `runtime/lib/esr/persistence/ets.ex:67`) — first step: `At boot, Persistence.Supervisor starts Ets with table :esr_actor_states (named/public/set).`
- **Telemetry: boot-time attach + event capture** (entry: `runtime/lib/esr/telemetry/supervisor.ex:20`) — first step: `Esr.Telemetry.Supervisor starts Buffer name=:default (retention_minutes from :esr config, default 15) — creates :esr_telemetry_default ordered_set ETS.`
- **Workspaces.Registry at runtime** (entry: `runtime/lib/esr/workspaces/registry.ex:37`) — first step: `On esrd boot, load_from_file("~/.esrd/<instance>/workspaces.yaml") parses into {name: Workspace{cwd, start_cmd, role, chats, env}} and each row is put into the :esr_workspaces ETS.`

**Notes:** Subsystem one-liners — (1) AdapterHub.Registry: maps `adapter:<name>/<instance_id>` topic → actor_id in ETS, monitors each actor pid so DOWN auto-evicts its bindings (S5); Python adapter subprocess registration is indirect — the Instantiator calls bind_adapter and WorkerSupervisor.ensure_adapter in lockstep, then the Python adapter_runner joins the Phoenix channel, inbound pushes look up the bound actor_id and forward to PeerServer. (2) HandlerRouter.call: Phoenix.PubSub.subscribe on handler_reply:<id> → broadcast handler_call envelope on handler:<module>/default → receive matching :handler_reply or time out (5 s default) — v0.1 is a singleton worker per module; F10 pool adds round-robin without changing this contract. (3) Instantiator steps: check_params → validate_workspace_apps → substi …

## runtime-web

**Path:** `runtime/lib/esr_web`

**Description:** Phoenix web tier of the ESR Elixir runtime. Exposes three WebSocket sockets (adapter_hub, handler_hub, channel) plus the CliChannel (mounted on the handler socket) that collectively form the sole network surface Python processes (adapter_runners, handler_workers, the esr CLI, and the esr-channel MCP bridge) use to talk to the runtime. There are no HTTP endpoints in v0.1/v0.2 — the router is empty and every interaction is a Phoenix Channel RPC or server-push. ChannelChannel + ChannelSocket were added in v0.2 for the MCP bridge and carry the tool_invoke / notification / session_register envelopes between Claude Code instances, the runtime, and Feishu.

**Test baseline:** exit=1, passed=23, failed=3, skipped=0

```
cd /home/yaosh/projects/esr/runtime && MIX_ENV=test mix test test/esr_web/channel_channel_test.exs test/esr_web/channel_integration_test.exs test/esr_web/cli_channel_test.exs test/esr_web/controllers/error_json_test.exs
```


**Key interfaces:**

- **endpoint_http_port**: `dev`=4000, `test`=4002, `prod_default`=4001, `bind_ip`=127.0.0.1 (loopback), `note`=Port is fetched at runtime by CliChannel.phoenix_p

- **http_routes**: `router_module`=EsrWeb.Router, `routes`=[], `note`=Router has zero scope/pipeline/get/post declaratio

- **sockets**
  - `?` — 
  - `?` — 
  - `?` — 

- **channels**
  - `?` — 
  - `?` — 
  - `?` — 
  - `?` — 

**Dependencies:**
- **external**: ['phoenix — Phoenix.Endpoint, Phoenix.Socket, Phoenix.Channel, Phoenix.Controller', 'phoenix_pubsub — EsrWeb.PubSub used for directive_ack:<id> and handler_reply:<id> broadcasts', 'plug — Plug.Static,
- **internal_runtime**: ['Esr.AdapterHub.Registry (topic <-> actor_id binding ETS, shared across tests)', 'Esr.Entity.Registry (actor_id -> PID; looked up by AdapterChannel.forward and ChannelChannel.tool_invoke)', 'Esr.PeerSer

**User flows:**
- **** — first step: `Python adapter_runner WebSocket connects to ws://HOST:PORT/adapter_hub/socket/websocket?vsn=2.0.0`
- **** — first step: `PeerServer.emit_and_track broadcasts a directive envelope to the topic adapter:<name>/<instance_id> using EsrWeb.Endpoint.broadcast`
- **** — first step: `HandlerRouter.call subscribes Phoenix.PubSub -> handler_reply:<id>`
- **** — first step: `Python CLI (py/src/esr/cli/runtime_bridge.py) opens a short-lived WS to ws://HOST:PORT/handler_hub/socket/websocket?vsn=2.0.0`
- **** — first step: `esr-channel Python process (spawned per Claude Code session) opens WS to ws://HOST:PORT/channel/socket/websocket?vsn=2.0.0`
- **** — first step: `Runtime code (e.g. inbound Feishu message handler) calls Esr.SessionRegistry.notify_session(sid, envelope)`

**Notes:** ['All four socket mounts live in endpoint.ex (adapter_hub, handler_hub, channel). CliChannel is deliberately NOT on its own socket — it is mounted on EsrWeb.HandlerSocket under `channel "cli:*"`. That is why the CLI\'s runtime_bridge targets /handler_hub/socket (see py/src/esr/cli/runtime_bridge.py and the py-cli module report, which confirms ESR_HANDLER_HUB_URL is the CLI\'s RPC endpoint).', 'Router.ex is a one-liner: zero HTTP routes in v0.1/v0.2. The only Plug pipeline is in endpoint.ex (Plug.Static, Plug.RequestId, Plug.Telemetry, Plug.Parsers, Plug.Session, Plug.Router). ErrorJSON handles fallback 404/500 for any unmatched HTTP request.', "AdapterChannel's join comment is important: join must succeed even when no binding exists, because Python adapter workers are spawned before topology instantiation (so they can be on the topic when init_directive broadcasts). Binding resolution is deferred to forward/2, which replies {:error, no_binding} instead of crashing.", "AdapterChannel's directive_ack dual-publish pattern is structural: PubSub topic directive_ack:<id> decouples the correlator (PeerServer.emit_and_track or Instantiator) from the adapter binding, and the tagged send to the PeerServer is a fallback so F09 routing invariants hold even if no correlator is subscribed.", 'ChannelChannel.handle_in("envelope", kind=tool_invoke, ...) is the V0.2 tool-bridge entry point. It hard-codes the peer name as "thread:<session_id>" — the thread PeerServer MUST be registered under that exact actor_id. The feishu_thread PeerServer is instantiated by the feishu-thread-session topology artifact which the CLI triggers via cli:run/feishu-thread-session.', 'CliChannel.dispatch fallback (line 265) returns a structured error envelope rather than an echo — this closes reviewer-C2 (no silent success for typos). Any unknown/unimplemented cli:* topic surfaces as %{data: %{error: "unknown_topic: ..."}}.', 'CliChannel.dispatch("cli:adapter/start/<type>") auto-spawns the adapter_runner Python process with a hard-coded URL ws://127.0.0.1:<phoenix_port>/adapter_hub/socket/websocket?vsn=2.0.0 — this is how `esr adapter add --type feishu` auto-bootstraps the adapter, per main.py:375 _auto_instantiate_feishu_app_session.', 'Three CliChannelTest cases flake under parallel test load (max_cases=16 + 100ms default assert_receive). In isolation the cli_channel_test passes 19/19 and the whole runtime-web suite passes 26/26. The default assert_receive timeout (100ms) is the bottleneck; raising it or using describe-level `@tag timeout: :infinity` and larger assert_receive timeouts would stabilise them. Considered a pre-existing test-harness issue rather than a runtime-web defect.', 'There is no authentication on any socket — connect/3 in all three sockets accepts any params and returns :ok. id/1 returns nil so there is no way for the runtime to force-disconnect a user session. This is documented as a v0.1 simplification; auth/tenancy belongs to a later phase.', 'EsrWeb.Telemetry module is instantiated but no reporter children are active (ConsoleReporter is commented out). Metrics are collected via :telemetry events but only the periodic poller runs; runtime telemetry consumed by CLI `esr trace` comes from Esr.Telemetry.Buffer (a separate ring buffer, not this module).']
