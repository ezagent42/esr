"""URL resolution helper — re-reads esrd.port between reconnect attempts.

Launchctl kickstart restarts a crashed esrd on a new port each time, so
clients must re-resolve on every connection attempt rather than caching
the URL from the ``--url`` CLI arg. The lookup is a file read plus a
netloc substitution; if the port file is missing or malformed, the
fallback URL (the CLI arg) is returned verbatim.
"""
from __future__ import annotations


def resolve_url(fallback_url: str) -> str:
    """Re-read ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` and substitute the
    port into ``fallback_url``'s authority.

    Returns ``fallback_url`` as-is if the port file is absent or does
    not contain a decimal string — the launchctl-unmanaged path
    (``mix phx.server`` on a fixed port) still works.
    """
    from urllib.parse import urlparse, urlunparse

    from esr.cli import paths

    port_file = paths.runtime_home() / "esrd.port"
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
