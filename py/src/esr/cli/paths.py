"""Filesystem path helpers for CLI commands.

Centralised so `esr cap list`, `esr adapter feishu create-app`, the admin
dispatcher clients, and the Feishu adapter all agree on where the runtime
state lives. Reads `ESRD_HOME` + `ESR_INSTANCE` env vars; defaults match
the Elixir runtime's `Esr.Paths` helpers.
"""
from __future__ import annotations

import os
from pathlib import Path


def esrd_home() -> Path:
    raw = os.environ.get("ESRD_HOME") or os.path.expanduser("~/.esrd")
    return Path(raw)


def current_instance() -> str:
    return os.environ.get("ESR_INSTANCE", "default")


def runtime_home() -> Path:
    return esrd_home() / current_instance()


def capabilities_yaml_path() -> str:
    return str(runtime_home() / "capabilities.yaml")


def adapters_yaml_path() -> Path:
    return runtime_home() / "adapters.yaml"


def workspaces_yaml_path() -> Path:
    return runtime_home() / "workspaces.yaml"


def users_yaml_path() -> Path:
    return runtime_home() / "users.yaml"


def commands_compiled_dir() -> Path:
    return runtime_home() / "commands" / ".compiled"


def admin_queue_dir() -> Path:
    return runtime_home() / "admin_queue"
