"""Port-file-aware URL resolution (shared by adapter + handler IPC).

Read ``$ESRD_HOME/$ESR_INSTANCE/esrd.port``; if present and numeric,
substitute its value into ``fallback_url``'s authority. Otherwise
return ``fallback_url`` unchanged.

See spec §5.3 F13 and docs/notes/tmux-socket-isolation.md for the
reconnect-on-launchctl-kickstart rationale.
"""
from __future__ import annotations

import os
import pathlib


def _runtime_home() -> pathlib.Path:
    """Return the local esrd's runtime home dir.

    Mirrors py/src/esr/ipc/url.py — reads $ESRD_HOME / $ESR_INSTANCE
    env vars (defaults: ~/.esrd / "default").
    """
    home = os.environ.get("ESRD_HOME") or os.path.expanduser("~/.esrd")
    instance = os.environ.get("ESR_INSTANCE", "default")
    return pathlib.Path(home) / instance


def resolve_url(fallback_url: str) -> str:
    """Re-read ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` and substitute the
    port into ``fallback_url``'s authority.

    Returns ``fallback_url`` as-is if the port file is absent or does
    not contain a decimal string — the launchctl-unmanaged path
    (``mix phx.server`` on a fixed port) still works.
    """
    from urllib.parse import urlparse, urlunparse

    port_file = _runtime_home() / "esrd.port"
    try:
        port_txt = port_file.read_text().strip()
    except (FileNotFoundError, OSError):
        return fallback_url
    if not port_txt.isdigit():
        return fallback_url

    parsed = urlparse(fallback_url)
    host = parsed.hostname or "127.0.0.1"
    new_netloc = f"{host}:{port_txt}"
    if parsed.username:
        creds = parsed.username
        if parsed.password:
            creds += f":{parsed.password}"
        new_netloc = f"{creds}@{new_netloc}"
    return urlunparse(parsed._replace(netloc=new_netloc))
