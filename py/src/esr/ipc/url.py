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
    4. Kind-specific default

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
        return DEFAULT_HANDLER_HUB_URL

    # kind in ("adapter", None) — default path
    specific = os.environ.get("ESR_ADAPTER_HUB_URL", "")
    if specific:
        return specific
    legacy = os.environ.get("ESR_RUNTIME_URL", "")
    if legacy:
        return legacy
    return DEFAULT_ADAPTER_HUB_URL
