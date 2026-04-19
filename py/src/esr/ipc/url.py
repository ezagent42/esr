"""Runtime URL discovery (PRD 03 F11).

Python-side processes (handler workers, adapter runners, CLI) find
the Phoenix endpoint via the ``ESR_RUNTIME_URL`` environment variable.
The default points at the dev esrd instance on localhost:4001 — the
documented layout from spec §3.8.

``esr use`` (PRD 07 F01) sets the env var on the shell; the processes
it spawns inherit it automatically.
"""

from __future__ import annotations

import os

DEFAULT_RUNTIME_URL: str = "ws://localhost:4001/adapter_hub/socket/websocket"
"""Documented default for the Phoenix adapter_hub socket."""


def discover_runtime_url(*, override: str | None = None) -> str:
    """Return the runtime WS URL.

    Priority: ``override`` argument > ``ESR_RUNTIME_URL`` env var >
    ``DEFAULT_RUNTIME_URL``. An empty env value is treated as unset.
    """
    if override:
        return override
    env = os.environ.get("ESR_RUNTIME_URL", "")
    if env:
        return env
    return DEFAULT_RUNTIME_URL
