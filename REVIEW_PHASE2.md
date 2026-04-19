# Phase 2 Review — ESR Python SDK

Performed by `superpowers:code-reviewer` subagent on 2026-04-19.
Scope: `py/src/esr/**`, `py/tests/**`, `py/pyproject.toml`.

## Summary
- Files reviewed: 19 lib + 30 test + pyproject + Makefile
- Critical findings: 3
- Significant findings: 7
- Minor findings: 5
- Overall: **PASS-WITH-FOLLOWUPS** — SDK covers all 19 FRs, 343 tests pass, mypy/ruff clean. C1+C2 are Phase 3 integration contracts (address during Phase 3 wiring), C3 is a ~10-min structural fix.

## Critical Findings

### C1 — `DEFAULT_RUNTIME_URL` covers only `/adapter_hub/socket`; no handler URL
**File:** `py/src/esr/ipc/url.py:16`, `py/src/esr/cli/main.py:44`
**Fix:** Split into `DEFAULT_ADAPTER_HUB_URL` and `DEFAULT_HANDLER_HUB_URL`. Add `kind` parameter to `discover_runtime_url()`.

### C2 — `schema_version` never appears in handler_call/reply wire format
**File:** `py/src/esr/ipc/envelope.py:105-126`, `handler_worker.py:36-77`
**Fix:** Attach `schema_version` in `_dump_state`, check in `process_handler_call`, return `SchemaVersionMismatch` error on drift. Add failing-load test.

### C3 — `Topology.nodes` contains mutable `_Node` despite frozen Topology
**File:** `py/src/esr/command.py:65-83`
**Fix:** Mark `_Node` as `@dataclass(frozen=True)` and make `params` + `init_directive` use `MappingProxyType`. Assert nodes-also-frozen in test.

## Significant Findings

- **S1** Emit/Route/InvokeCommand dict payloads not deep-frozen (`actions.py:25-48`)
- **S2** `@adapter` decorator doesn't enforce pure factory (CI-scan only — clarify docstring) (`adapter.py:42-60`)
- **S3** `process_handler_call` raises KeyError on malformed envelope despite "never raises" docstring (`handler_worker.py:35-77`)
- **S4** `compose.serial` deletes matched ports without adding edges (disconnected graph) (`command.py:201-237`)
- **S5** URI parser accepts IDs with embedded slashes (ambiguous vs Elixir) (`uri.py:97-101`)
- **S6** Purity scan `ast.walk` recurses into `if TYPE_CHECKING:` (false positives) (`verify/purity.py:60-91`)
- **S7** `ChannelClient._read_loop` catches per-message errors at loop level, forces reconnect (`ipc/channel_client.py:174-200`)

## Minor Findings

- **M1** Duplicated frozen-model detection in handler.py + verify/purity.py — extract helper.
- **M2** `compile_to_yaml` emits `params: [name, ...]` vs spec §6.3 `params: [{name, type, required}]` — doc debt, both sides tolerate.
- **M3** `_validate_init_directive` doesn't reject extra keys.
- **M4** `_check_cycles` silently accepts `depends_on` entries pointing outside topology — should raise.
- **M5** `uri.parse` preserves host case (`Localhost != localhost`).

## Notes (non-findings)

1. Tests thorough — parametric `test_handlers_cross_cutting.py` is a nice pattern.
2. `make_directive` asymmetrically absent from Python side (directives originate in Elixir) — correct by design.
3. `AdapterConfig` __slots__ + object.__setattr__ pattern is solid.
4. `@handler_state` supports both ConfigDict and dict idiomatic forms.
5. Open question for Phase 3: should `Event.from_envelope` reject `source=""`?

## Disposition

- **C1, C2** → defer to Phase 3 (integration contracts; resolve during WebSocket wiring).
- **C3** → tackle next iteration (structural fix).
- **S1–S7** → schedule across subsequent iterations per TDD discipline.
- **M1–M5** → REVIEW_FOLLOWUPS bulk-fix before Phase 8.
