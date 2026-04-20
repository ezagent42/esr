# ESR v0.1

Reference implementation of the [ESR Protocol v0.3](docs/design/ESR-Protocol-v0.3.md) (partial). Extracts the actor-networking substrate from cc-openclaw into an Elixir/OTP runtime plus a Python SDK of handlers, adapters, and composable command patterns.

## Status

v0.1 pre-conforming skeleton (ESR v0.3 §10.1 MUST capabilities land in v0.2). See:
- Design spec: [`docs/superpowers/specs/2026-04-18-esr-extraction-design.md`](docs/superpowers/specs/2026-04-18-esr-extraction-design.md)
- Implementation plan: [`docs/superpowers/plans/2026-04-18-esr-v0.1-implementation.md`](docs/superpowers/plans/2026-04-18-esr-v0.1-implementation.md)
- Progress checklist: [`CHECKLIST.md`](CHECKLIST.md)

## Quick start

```bash
# Launch a Claude Code session with this project's skills active
./esr-cc.sh

# Run the Elixir runtime (after Phase 1 lands)
cd runtime && iex -S mix

# Run the Python SDK tests (after Phase 2 lands)
cd py && uv run pytest

# Full test suite
make test
```

## Layout

| Path | Contents |
|---|---|
| `runtime/` | Elixir/OTP actor runtime (PeerServer, AdapterHub, HandlerRouter, Topology, Telemetry) |
| `py/` | Python SDK + `esr` CLI |
| `adapters/` | Shipped adapters (`feishu`, `cc_tmux`, …) |
| `handlers/` | Shipped handler modules (`feishu_app`, `feishu_thread`, `tmux_proxy`, `cc_session`) |
| `patterns/` | Shipped command patterns (`feishu-app-session`, `feishu-thread-session`) |
| `scenarios/` | E2E test scenarios |
| `docs/design/` | ESR v0.3 reference documents (read-only) |
| `docs/superpowers/specs/` | v0.1 design spec |
| `docs/superpowers/plans/` | v0.1 implementation plan |
| `docs/superpowers/prds/` | Per-subsystem PRDs (Phase 0B) |
| `docs/superpowers/tests/` | E2E test specification |

## Architecture

Four disciplined layers (see `docs/superpowers/specs/` §2):

- **Layer 1 — Actor Runtime (Elixir/OTP)** — PeerServer per actor, Phoenix.PubSub messaging, AdapterHub + HandlerRouter for IPC with Python
- **Layer 2 — Handler (Python, pure function)** — `(state, event) → (new_state, actions)`
- **Layer 3 — Adapter (Python, I/O)** — pure factory → impure I/O object, per-adapter I/O-permission declaration
- **Layer 4 — Command (Python, compile-time)** — typed open-graph pattern compiler; EDSL authoring + YAML canonical artifact

## License

To be added.
