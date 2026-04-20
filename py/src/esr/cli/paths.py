"""Filesystem path helpers for CLI commands.

Centralised so `esr cap list` and `esr cap show` agree on where
`capabilities.yaml` (and its sibling `permissions_registry.json`
snapshot) live. Reads `ESRD_HOME` env var with `~/.esrd` fallback to
match the runtime's `Esr.Capabilities.Supervisor.default_path/0`.
"""
from __future__ import annotations

import os
from pathlib import Path


def esrd_home() -> Path:
    """Return the active esrd home directory.

    Respects `ESRD_HOME` for tests that seed fixtures under `tmp_path`;
    falls back to `~/.esrd` for production use.
    """
    raw = os.environ.get("ESRD_HOME") or os.path.expanduser("~/.esrd")
    return Path(raw)


def capabilities_yaml_path() -> str:
    """Absolute path to the capabilities file the runtime watches.

    Returns a `str` (not `Path`) so callers can pass it verbatim to
    `yaml.safe_load(Path(p).read_text())` without forcing a
    `Path → str → Path` round-trip.
    """
    return str(esrd_home() / "default" / "capabilities.yaml")
