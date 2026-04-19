"""Command decorator + EDSL (PRD 02 F09 / F10; §6).

A Command is a named, parametric topology-builder. Pattern authors
write:

    @command("feishu-to-cc")
    def feishu_to_cc() -> None:
        port.input("from_feishu", type="FeishuMsg")
        a = node(id="thread-proxy", actor_type="feishu_thread", handler="on_msg")
        b = node(id="cc-session", actor_type="cc_session", handler="on_msg")
        a >> b

`compile_topology(name)` executes the registered function inside a
``_command_context`` so that ``node()`` calls and ``>>`` edges are
captured in a context-local ``_CommandCtx`` accumulator.

This module currently implements:
- F09: `@command` decorator + ``COMMAND_REGISTRY``
- F10: ``node()`` + ``>>`` edges + ``init_directive`` plumbing

F11 (port), F12 (compose.serial), F13 (compile_topology) and F14
(compile_to_yaml) follow.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
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
    """Register a command-building function under ``name``."""

    def decorate(fn: CommandFn) -> CommandFn:
        if name in COMMAND_REGISTRY:
            raise ValueError(f"command {name} already registered")
        COMMAND_REGISTRY[name] = CommandEntry(name=name, fn=fn)
        return fn

    return decorate


# --- EDSL -----------------------------------------------------------------


@dataclass
class _Node:
    """A node in a command's topology graph (PRD 02 F10)."""

    id: str
    actor_type: str
    handler: str
    adapter: str | None = None
    params: dict[str, Any] | None = None
    depends_on: tuple[str, ...] = ()
    init_directive: dict[str, Any] | None = None

    def __rshift__(self, other: _Node) -> _Node:
        """``a >> b`` records an edge a.id -> b.id in the current context."""
        ctx = _CURRENT.get(None)
        if ctx is None:
            raise RuntimeError("`>>` used outside a command context")
        ctx.edges.append((self.id, other.id))
        return other


@dataclass
class _CommandCtx:
    """Accumulator state for a command's compile context."""

    name: str
    nodes: list[_Node] = field(default_factory=list)
    edges: list[tuple[str, str]] = field(default_factory=list)
    ports_in: dict[str, str] = field(default_factory=dict)
    ports_out: dict[str, str] = field(default_factory=dict)


_CURRENT: ContextVar[_CommandCtx | None] = ContextVar("_esr_command_ctx", default=None)


@contextmanager
def _command_context(name: str) -> Iterator[_CommandCtx]:
    """Enter a fresh command-build context.

    Used by ``compile_topology`` (F13) and directly by tests that want
    to exercise ``node()`` / ``>>`` without the full compile pipeline.
    """
    ctx = _CommandCtx(name=name)
    token = _CURRENT.set(ctx)
    try:
        yield ctx
    finally:
        _CURRENT.reset(token)


def node(
    *,
    id: str,  # noqa: A002 — `id` is the spec-defined keyword
    actor_type: str,
    handler: str,
    adapter: str | None = None,
    params: dict[str, Any] | None = None,
    depends_on: Iterable[str] | None = None,
    init_directive: dict[str, Any] | None = None,
) -> _Node:
    """Declare a node in the current command's topology."""
    ctx = _CURRENT.get(None)
    if ctx is None:
        raise RuntimeError("node() called outside a command context")

    if init_directive is not None:
        _validate_init_directive(init_directive)

    n = _Node(
        id=id,
        actor_type=actor_type,
        handler=handler,
        adapter=adapter,
        params=dict(params) if params else None,
        depends_on=tuple(depends_on) if depends_on else (),
        init_directive=dict(init_directive) if init_directive else None,
    )
    ctx.nodes.append(n)
    return n


def _validate_init_directive(d: dict[str, Any]) -> None:
    """Check shape of an ``init_directive`` dict — ``{action: str, args: dict}``."""
    if "action" not in d or not isinstance(d["action"], str):
        raise TypeError(
            "init_directive must be {'action': str, 'args': dict}; missing/invalid 'action'"
        )
    if "args" in d and not isinstance(d["args"], dict):
        raise TypeError(
            "init_directive must be {'action': str, 'args': dict}; 'args' must be dict"
        )


# --- Ports (F11) ---------------------------------------------------------


class _Port:
    """Namespace for ``port.input`` / ``port.output`` — a stateless
    adapter over the current ``_CommandCtx``."""

    @staticmethod
    def input(name: str, type: str) -> str:  # noqa: A002
        """Record a typed input port. Returns ``name`` (so it can be used as a node id)."""
        ctx = _CURRENT.get(None)
        if ctx is None:
            raise RuntimeError("port.input() called outside a command context")
        if name in ctx.ports_in:
            raise ValueError(f"input port {name} already declared")
        ctx.ports_in[name] = type
        return name

    @staticmethod
    def output(name: str, type: str) -> str:  # noqa: A002
        """Record a typed output port. Returns ``name``."""
        ctx = _CURRENT.get(None)
        if ctx is None:
            raise RuntimeError("port.output() called outside a command context")
        if name in ctx.ports_out:
            raise ValueError(f"output port {name} already declared")
        ctx.ports_out[name] = type
        return name


port = _Port()
"""Namespace object — call ``port.input(name, type)`` / ``port.output(...)``."""
