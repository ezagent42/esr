"""Command decorator + EDSL (PRD 02 F09+; §6).

A Command is a named, parametric topology-builder. Pattern authors
write:

    @command("feishu-to-cc")
    def feishu_to_cc() -> None:
        port.input("from_feishu", type="FeishuMsg")
        node(id="thread-proxy", actor_type="feishu_thread", handler="on_msg")
        node(id="cc-session", actor_type="cc_session", handler="on_msg")
        ...

`compile_topology(name)` executes the registered function in a fresh
context, collecting nodes / edges / ports through module-level
``contextvars``. The decorated function itself returns nothing; its
side-effects are captured by the compiler.

This module currently implements F09 only; F10–F14 (node/port/compose,
compile_topology, compile_to_yaml) follow.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

CommandFn = Callable[..., Any]


@dataclass(frozen=True)
class CommandEntry:
    """A registered command. See PRD 02 F09."""

    name: str
    fn: CommandFn


COMMAND_REGISTRY: dict[str, CommandEntry] = {}
"""Global command registry — key is the command's declared ``name``."""


def command(name: str) -> Callable[[CommandFn], CommandFn]:
    """Register a command-building function under ``name``.

    Returns the decorated function unchanged. Duplicate names raise
    ``ValueError`` — the v0.1 runtime treats command name collisions
    as a packaging bug that must surface at import time.
    """

    def decorate(fn: CommandFn) -> CommandFn:
        if name in COMMAND_REGISTRY:
            raise ValueError(f"command {name} already registered")
        COMMAND_REGISTRY[name] = CommandEntry(name=name, fn=fn)
        return fn

    return decorate
