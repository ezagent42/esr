"""workspaces.yaml read/write helpers (spec §5.1).

Schema (schema_version: 1):
  workspaces:
    <name>:
      cwd: <path>
      start_cmd: <cmd>
      role: <role>
      chats:
        - {chat_id, app_id, kind: dm|group}
      env: {KEY: VAL, ...}
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

SCHEMA_VERSION = 1


@dataclass(frozen=True)
class Workspace:
    name: str
    cwd: str
    start_cmd: str
    role: str
    chats: list[dict[str, str]] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)


def read_workspaces(path: Path) -> dict[str, Workspace]:
    """Parse a workspaces.yaml into `{name: Workspace}`. Missing file → {}."""
    if not path.exists():
        return {}

    doc = yaml.safe_load(path.read_text()) or {}
    out: dict[str, Workspace] = {}
    for name, row in (doc.get("workspaces") or {}).items():
        out[name] = Workspace(
            name=name,
            cwd=row.get("cwd", ""),
            start_cmd=row.get("start_cmd", ""),
            role=row.get("role", "dev"),
            chats=list(row.get("chats") or []),
            env=dict(row.get("env") or {}),
        )
    return out


def write_workspace(path: Path, workspace: Workspace) -> None:
    """Append a workspace to the YAML at `path`. Fails if name exists.

    Creates parent directories as needed. Preserves other workspaces.
    """
    path.parent.mkdir(parents=True, exist_ok=True)

    if path.exists():
        doc = yaml.safe_load(path.read_text()) or {}
    else:
        doc = {}

    doc.setdefault("schema_version", SCHEMA_VERSION)
    workspaces = doc.setdefault("workspaces", {})

    if workspace.name in workspaces:
        raise ValueError(f"workspace {workspace.name!r} already exists")

    workspaces[workspace.name] = {
        "cwd": workspace.cwd,
        "start_cmd": workspace.start_cmd,
        "role": workspace.role,
        "chats": workspace.chats,
        "env": workspace.env,
    }

    path.write_text(yaml.safe_dump(doc, sort_keys=True))


def remove_workspace(path: Path, name: str) -> bool:
    """Remove a workspace by name. Returns True if removed, False if absent."""
    if not path.exists():
        return False
    doc = yaml.safe_load(path.read_text()) or {}
    ws = doc.get("workspaces") or {}
    if name not in ws:
        return False
    del ws[name]
    path.write_text(yaml.safe_dump(doc, sort_keys=True))
    return True
