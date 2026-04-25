"""Runtime URL discovery (PRD 03 F11).

Python-side processes (handler workers, adapter runners, CLI) find
the Phoenix endpoint via environment variables. The runtime exposes
two distinct WebSocket endpoints per spec §3.3 / §7.1:

- ``/adapter_hub/socket`` — for adapter processes
- ``/handler_hub/socket`` — for handler workers

Phoenix routes by socket path, so the same URL cannot serve both.
Reviewer C1 in the Phase 2 review called out that the Python side
was hardcoding only the adapter path — any handler-worker
orchestration would silently connect to the wrong socket.

Callers pass ``kind="adapter"`` or ``kind="handler"`` to pick the
right default; the kind-agnostic legacy form (``ESR_RUNTIME_URL``)
remains as a backward-compat alias for adapter_hub.

``esr use`` (PRD 07 F01) sets the env vars on the shell; processes
it spawns inherit them automatically.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Literal

DEFAULT_ADAPTER_HUB_URL: str = "ws://localhost:4001/adapter_hub/socket/websocket?vsn=2.0.0"
"""Default Phoenix adapter_hub socket URL for adapters (vsn=2.0.0 selects
the array-frame V2 JSON serializer; V1 expects map frames and rejects
our list-shaped phx_join)."""

DEFAULT_HANDLER_HUB_URL: str = "ws://localhost:4001/handler_hub/socket/websocket?vsn=2.0.0"
"""Default Phoenix handler_hub socket URL for handler workers (vsn=2.0.0)."""

DEFAULT_RUNTIME_URL: str = DEFAULT_ADAPTER_HUB_URL
"""Legacy alias — old callers default to the adapter socket."""

Kind = Literal["adapter", "handler"]


def _read_port_file() -> int | None:
    """Read ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` if present.

    Mirrors the shape `esr_cc_mcp.channel._resolve_from_port_file` uses
    — the same port file is the source of truth for *any* CLI that
    needs to talk to a running esrd on a non-default port (dev, e2e
    harness running a throwaway esrd on a dynamic port, etc.).
    """
    home = os.environ.get("ESRD_HOME") or os.path.expanduser("~/.esrd")
    instance = os.environ.get("ESR_INSTANCE", "default")
    port_file = Path(home) / instance / "esrd.port"
    try:
        txt = port_file.read_text().strip()
    except (FileNotFoundError, OSError):
        return None
    return int(txt) if txt.isdigit() else None


def _default_with_port_file(socket_path: str, fallback: str) -> str:
    """Return ``ws://127.0.0.1:<port_file>/<socket_path>`` when the
    port file is readable; else ``fallback`` (the compile-time default
    pointing at 4001).
    """
    port = _read_port_file()
    if port is None:
        return fallback
    return f"ws://127.0.0.1:{port}/{socket_path}/websocket?vsn=2.0.0"


def discover_runtime_url(
    *,
    override: str | None = None,
    kind: Kind | None = None,
) -> str:
    """Return the runtime WS URL for a given socket kind.

    Priority (highest first):
    1. ``override`` argument
    2. ``ESR_ADAPTER_HUB_URL`` / ``ESR_HANDLER_HUB_URL`` (kind-specific env var)
    3. ``ESR_RUNTIME_URL`` (kind-agnostic legacy env var)
    4. ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` — authoritative for an
       actually-running esrd on a non-default port (e2e harness, dev
       mix phx.server with PORT override, etc.)
    5. Kind-specific default (localhost:4001)

    If ``kind`` is ``None`` (legacy callers), behaves as before —
    returns the adapter_hub URL via ``ESR_RUNTIME_URL`` or the
    adapter default.

    An empty env value is treated as unset.
    """
    if override:
        return override

    if kind == "handler":
        specific = os.environ.get("ESR_HANDLER_HUB_URL", "")
        if specific:
            return specific
        legacy = os.environ.get("ESR_RUNTIME_URL", "")
        if legacy:
            return legacy
        return _default_with_port_file("handler_hub/socket", DEFAULT_HANDLER_HUB_URL)

    # kind in ("adapter", None) — default path
    specific = os.environ.get("ESR_ADAPTER_HUB_URL", "")
    if specific:
        return specific
    legacy = os.environ.get("ESR_RUNTIME_URL", "")
    if legacy:
        return legacy
    return _default_with_port_file("adapter_hub/socket", DEFAULT_ADAPTER_HUB_URL)
