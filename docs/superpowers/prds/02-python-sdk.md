# PRD 02 — Python SDK

**Spec reference:** §4 Handler, §5 Adapter, §6 Command, §7.5 URI
**E2E tracks:** A (install flow), B (InvokeCommand), C (handler/adapter behaviour), H (correctness)
**Plan phase:** Phase 2

---

## Goal

Provide the Python-side authoring surface: `@handler`, `@adapter`, `@command` decorators; Action / Event / Directive dataclasses; the EDSL compiler that produces canonical YAML topology artifacts; a CI-enforceable purity check. This SDK is the single entry point for everyone writing v0.1 handlers / adapters / patterns — it must be small, obvious, and unsurprising.

## Non-goals

- CLI (PRD 07)
- IPC transport (PRD 03)
- Any specific handler / adapter / pattern shipped with v0.1 (PRDs 04-06)
- Python sandboxing (rejected in design — CI-time purity only)

## Functional Requirements

### F01 — Package skeleton
`py/pyproject.toml` targets Python 3.11+, `uv`-managed. Deps: `pydantic>=2.5`, `aiohttp>=3.9`, `click>=8.1`, `pyyaml>=6.0`, `anyio>=4.0`. Dev deps: `pytest`, `pytest-asyncio`, `ruff`, `mypy`. Sets `[project.scripts] esr = "esr.cli.main:cli"`. Layout: `src/esr/` with subpackages `ipc`, `cli`, `verify`. **Unit test:** `uv build` succeeds; `uv run python -c "import esr; print(esr.__version__)"` prints `0.1.0`.

### F02 — Actions
`esr.actions` exposes exactly three frozen dataclasses: `Emit(adapter, action, args)`, `Route(target, msg)`, `InvokeCommand(name, params)`. Plus type alias `Action = Union[Emit, Route, InvokeCommand]`. Instances are frozen (mutation raises). Equality is structural. **Unit test:** `tests/test_actions.py` per plan Task 2.2.

### F03 — Events & Directives
`esr.events` exposes frozen dataclasses: `Event(source, event_type, args)` and `Directive(adapter, action, args)`. Helper `Event.from_envelope(dict) -> Event` deserialises IPC payloads. **Unit test:** `tests/test_events.py`.

### F04 — `@handler` decorator
`esr.handler.handler(*, actor_type, name)` decorator registers a callable under key `f"{actor_type}.{name}"` in `HANDLER_REGISTRY`. Duplicate registration raises `ValueError(f"handler {key} already registered")`. The decorator returns the original function unchanged so it is still directly callable. **Unit test:** `tests/test_handler.py` covers register, invocation, duplicate rejection.

### F05 — `@handler_state` decorator
`esr.handler.handler_state(*, actor_type, schema_version)` decorator registers a pydantic `BaseModel` (required `frozen=True` via model_config) in `STATE_REGISTRY`. One state model per actor_type. The `schema_version` field is attached to persisted state (PRD 01 F18) and compared on load (spec §4.5). Mismatch → runtime refuses to load. **Unit test:** `tests/test_handler.py` — register, mismatch rejection.

### F06 — Handler registry introspection
`esr.handler.HANDLER_REGISTRY` is a `dict[str, HandlerEntry]` and can be cleared in tests. `HandlerEntry(actor_type, name, fn)` is a frozen dataclass. Similar for `STATE_REGISTRY` / `StateEntry`. **Unit test:** `tests/test_handler.py`.

### F07 — `@adapter` decorator
`esr.adapter.adapter(*, name, allowed_io)` decorator registers a class under `name` in `ADAPTER_REGISTRY`. Enforces that the class has a static `factory(actor_id, config)` method — raises `TypeError` otherwise. `allowed_io: dict[str, Any]` is stored and later used by CI capability scan (PRD 02 F14). **Unit test:** `tests/test_adapter.py` covers register, factory-missing rejection, duplicate rejection.

### F08 — `AdapterConfig`
`esr.adapter.AdapterConfig` wraps a `dict` and exposes read-only attribute access (`.app_id` resolves via `_data["app_id"]`, `AttributeError` if absent). Setting an attribute raises. **Unit test:** `tests/test_adapter.py` — attr access, unknown-attr raises, setattr raises.

### F09 — `@command` decorator
`esr.command.command(name)` registers the decorated function under `name` in `COMMAND_REGISTRY`. Duplicate registration raises `ValueError`. The function body uses the EDSL (`node`, `port`, `compose.serial`) to build a pattern in a context-local accumulator. **Unit test:** `tests/test_command.py`.

### F10 — EDSL: `node()`
`esr.command.node(*, id, actor_type, handler, adapter=None, params=None, depends_on=None)` creates a `_Node` instance and appends it to the current command's node list (via `contextvars`). The returned `_Node` supports `>>` operator overload: `a >> b` records an edge from `a` to `b` in the current command context. **Unit test:** `tests/test_command.py` — node counted, edge recorded.

### F11 — EDSL: `port`
`esr.command.port.input(name, type)` / `.output(name, type)` record a typed port on the current pattern and return the port name (so it can be used as a node `id`). Calling outside a `@command` function raises `RuntimeError`. **Unit test:** `tests/test_command.py`.

### F12 — EDSL: `compose.serial`
`esr.command.compose.serial(a_pattern, b_pattern)` runs both inside the current command context and matches shared port names. Type equality required (no subtype in v0.1). Shared ports merged into one node (CSE). Top-level unmatched ports error. **Unit test:** `tests/test_command_compose.py` — serial with shared port / type mismatch / unmatched ports.

### F13 — `compile_topology(name)`
`esr.command.compile_topology(name)` executes the registered command function in a fresh context, validates no depends_on cycles (Kahn's algorithm), extracts `{{param}}` templates into a deduplicated sorted tuple, applies dead-node elimination and CSE, and returns a frozen `Topology` dataclass: `(name, nodes, edges, ports_in, ports_out, params)`. **Unit test:** `tests/test_command.py` — single pattern / composed / cycle rejection / param extraction.

### F14 — `compile_to_yaml(topology, path)`
`esr.command.compile_to_yaml(topo, path)` serialises a compiled `Topology` to a YAML file matching the schema in spec §6.3 (schema_version, name, params, ports, nodes, edges). Deterministic key ordering (explicit sort) so diffs are stable. **Unit test:** `tests/test_command_yaml.py` — round-trip (compile → YAML → reload → equal).

### F15 — URI parser
`esr.uri.parse(s)` accepts `esr://[org@]host[:port]/<type>/<id>[?params]`. Empty host raises `ValueError("empty host")`. Unknown type raises `ValueError("unknown type")`. Returns `EsrURI` frozen dataclass. `esr.uri.build(type_, id_, *, host, port=None, org=None)` builds a canonical URI. **Unit test:** `tests/test_uri.py` — parse all examples from spec §7.5; build; empty host rejection.

### F16 — Purity enforcement (Check 1: import allow-list)
`esr.verify.purity.scan_imports(path) -> list[Violation]` walks a handler module's AST and flags any top-level `import` of modules outside the allow-list (`esr`, `typing`, `dataclasses`, `pydantic`, `enum`, plus modules declared in the handler's `esr.toml` `allowed_imports`). Violations reported with line numbers. Integrated into `esr-lint` (PRD 07 F14). **Unit test:** `tests/test_purity_imports.py` — scan a module with `import requests` fails with specific message.

### F17 — Purity enforcement (Check 2: frozen-state harness)
`esr.verify.purity.frozen_state_fixture(state_cls)` pytest fixture produces a frozen instance of a pydantic model. Any mutation attempt on the instance raises `pydantic.ValidationError` (pydantic's own enforcement of `frozen=True`). Every handler in `handlers/` has at least one unit test using this fixture. **Unit test:** meta-test that asserts the fixture raises on mutation.

### F18 — Capability scan for adapters
`esr.verify.capability.scan_adapter(module_path) -> list[Violation]` walks an adapter module and verifies every import matches a prefix in `allowed_io` (the dict passed to `@adapter`). Violations include the offending import and the allowed prefixes for reference. **Unit test:** `tests/test_capability.py` — adapter using `requests` without declaring it fails; adapter using `lark_oapi.api.im.v1` when `lark_oapi="*"` declared passes.

### F19 — Package entry points
`esr/__init__.py` re-exports the public API: `handler`, `handler_state`, `adapter`, `AdapterConfig`, `command`, `node`, `port`, `compose`, `Emit`, `Route`, `InvokeCommand`, `Event`, `Directive`, `EsrURI`. Users import from `esr` directly, not submodules. **Unit test:** `tests/test_public_api.py` — asserts every name imports.

## Non-functional Requirements

- **Static typing:** `mypy --strict` clean on `src/esr/`
- **Lint:** `ruff check` clean
- **Format:** `ruff format` — checked in CI
- **Test coverage:** ≥ 90% line coverage on `src/esr/` (measured by `pytest-cov`)
- **Python version:** 3.11+ (use `match` statements, frozen dataclass syntax, `list[int]` generics)

## Dependencies

- PRD 01 is technically independent but the combined E2E needs both. SDK can be built in parallel with runtime (plan Phase 1 + Phase 2).

## Unit-test matrix

| FR | Test file | Test name |
|---|---|---|
| F01 | — | manual: `uv build` |
| F02 | `py/tests/test_actions.py` | Emit frozen / Route requires target / InvokeCommand / equality |
| F03 | `py/tests/test_events.py` | Event / Directive |
| F04 | `py/tests/test_handler.py` | register / call / duplicate |
| F05 | `py/tests/test_handler.py` | state register / duplicate |
| F06 | `py/tests/test_handler.py` | registry clear |
| F07 | `py/tests/test_adapter.py` | register / factory missing / duplicate |
| F08 | `py/tests/test_adapter.py` | attr access / unknown / readonly |
| F09 | `py/tests/test_command.py` | register / duplicate |
| F10 | `py/tests/test_command.py` | node + edge |
| F11 | `py/tests/test_command.py` | port.input / port.output / outside-context |
| F12 | `py/tests/test_command_compose.py` | serial |
| F13 | `py/tests/test_command.py` | compile / cycle / params |
| F14 | `py/tests/test_command_yaml.py` | YAML round-trip |
| F15 | `py/tests/test_uri.py` | parse / build / errors |
| F16 | `py/tests/test_purity_imports.py` | scan imports |
| F17 | `py/tests/test_purity_frozen.py` | frozen fixture raises |
| F18 | `py/tests/test_capability.py` | adapter capability scan |
| F19 | `py/tests/test_public_api.py` | public API imports |

## Acceptance

- [ ] All 19 FRs have passing unit tests
- [ ] `uv run pytest` green; `uv run ruff check` clean; `uv run mypy --strict src/` clean
- [ ] Coverage ≥ 90%
- [ ] `esr-lint handlers/` detects a deliberately-introduced violation (smoke)
- [ ] Cross-compat: a handler using `@handler` + `@handler_state` + returning `[Emit, Route, InvokeCommand]` compiles and passes purity unit tests

---

*End of PRD 02.*
