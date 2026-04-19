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

import re
from collections.abc import Callable, Iterable, Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Any, cast

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


# --- Composition (F12) ---------------------------------------------------


PatternFn = Callable[[], None]


class _Compose:
    """Namespace for ``compose.serial(a, b)`` and future compose variants."""

    @staticmethod
    def serial(a: PatternFn, b: PatternFn) -> None:
        """Compose two pattern-builder functions in series.

        Runs each in its own sub-context, matches shared port names
        across A's outputs and B's inputs (type-equality required),
        and merges remaining nodes/edges/ports into the outer
        command context. Raises ``ValueError`` when there is no
        shared port to wire through (serial requires at least one
        hand-off point).
        """
        outer = _CURRENT.get(None)
        if outer is None:
            raise RuntimeError("compose.serial called outside a command context")

        ctx_a = _run_subpattern(a, f"{outer.name}/A")
        ctx_b = _run_subpattern(b, f"{outer.name}/B")

        shared = set(ctx_a.ports_out) & set(ctx_b.ports_in)
        if not shared:
            raise ValueError(
                "no shared port between serial patterns — compose.serial requires "
                "at least one A-output name matching a B-input name"
            )

        for name in shared:
            if ctx_a.ports_out[name] != ctx_b.ports_in[name]:
                raise TypeError(
                    f"port {name} type mismatch: "
                    f"A outputs {ctx_a.ports_out[name]!r}, "
                    f"B inputs {ctx_b.ports_in[name]!r}"
                )
            del ctx_a.ports_out[name]
            del ctx_b.ports_in[name]

        _merge_into(outer, ctx_a)
        _merge_into(outer, ctx_b)


compose = _Compose()
"""Namespace object — call ``compose.serial(a_fn, b_fn)``."""


def _run_subpattern(fn: PatternFn, name: str) -> _CommandCtx:
    """Run ``fn`` in a fresh sub-context; return the accumulator."""
    sub = _CommandCtx(name=name)
    token = _CURRENT.set(sub)
    try:
        fn()
    finally:
        _CURRENT.reset(token)
    return sub


def _merge_into(outer: _CommandCtx, sub: _CommandCtx) -> None:
    """Copy a sub-context's nodes/edges/ports into ``outer``.

    Port type collisions across patterns raise ``TypeError`` — the
    v0.1 type system has no subtyping.
    """
    outer.nodes.extend(sub.nodes)
    outer.edges.extend(sub.edges)
    for name, type_ in sub.ports_in.items():
        if name in outer.ports_in and outer.ports_in[name] != type_:
            raise TypeError(
                f"port {name} type mismatch on compose: {outer.ports_in[name]!r} vs {type_!r}"
            )
        outer.ports_in[name] = type_
    for name, type_ in sub.ports_out.items():
        if name in outer.ports_out and outer.ports_out[name] != type_:
            raise TypeError(
                f"port {name} type mismatch on compose: {outer.ports_out[name]!r} vs {type_!r}"
            )
        outer.ports_out[name] = type_


# --- Compile (F13) -------------------------------------------------------


@dataclass(frozen=True)
class Topology:
    """A compiled command — the immutable output of ``compile_topology``."""

    name: str
    nodes: tuple[_Node, ...]
    edges: tuple[tuple[str, str], ...]
    ports_in: MappingProxyType[str, str]
    ports_out: MappingProxyType[str, str]
    params: tuple[str, ...]


_PARAM_RE = re.compile(r"\{\{(\w+)\}\}")


def compile_topology(name: str) -> Topology:
    """Compile a registered command into a frozen ``Topology``.

    Steps:
    1. Execute the command's fn in a fresh context (collect nodes / edges / ports).
    2. Validate the ``depends_on`` graph is acyclic (Kahn's algorithm).
    3. Extract ``{{param}}`` references from node params and init_directive args.
    4. Return a frozen Topology dataclass.

    Dead-node elimination and CSE are covered by PRD 06 F05 / F06 and
    the ``Topology`` schema is stable across those optimizations.
    """
    entry = COMMAND_REGISTRY.get(name)
    if entry is None:
        raise KeyError(f"command {name} not registered")

    ctx = _CommandCtx(name=name)
    token = _CURRENT.set(ctx)
    try:
        entry.fn()
    finally:
        _CURRENT.reset(token)

    _check_cycles(ctx.nodes)
    params = tuple(sorted(_extract_params(ctx.nodes)))

    return Topology(
        name=name,
        nodes=tuple(ctx.nodes),
        edges=tuple(ctx.edges),
        ports_in=MappingProxyType(dict(ctx.ports_in)),
        ports_out=MappingProxyType(dict(ctx.ports_out)),
        params=params,
    )


def _check_cycles(nodes: list[_Node]) -> None:
    """Raise ``ValueError`` if the ``depends_on`` relation has a cycle."""
    indeg: dict[str, int] = {n.id: 0 for n in nodes}
    edges: dict[str, list[str]] = {n.id: [] for n in nodes}
    for n in nodes:
        for dep in n.depends_on:
            if dep not in indeg:
                continue  # dep points outside this pattern — treat as external
            edges[dep].append(n.id)
            indeg[n.id] += 1

    ready = [nid for nid, d in indeg.items() if d == 0]
    seen = 0
    while ready:
        nid = ready.pop()
        seen += 1
        for nxt in edges[nid]:
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                ready.append(nxt)

    if seen != len(nodes):
        raise ValueError("cycle in depends_on")


def _extract_params(nodes: list[_Node]) -> set[str]:
    """Scan node params + init_directive args for ``{{name}}`` templates."""
    found: set[str] = set()
    for n in nodes:
        if n.params:
            _collect_params_from(n.params, found)
        if n.init_directive:
            args = n.init_directive.get("args")
            if isinstance(args, dict):
                _collect_params_from(cast(dict[str, Any], args), found)
    return found


def _collect_params_from(d: dict[str, Any], out: set[str]) -> None:
    """Walk a dict (values only) and collect ``{{name}}`` template names."""
    for v in d.values():
        if isinstance(v, str):
            out.update(_PARAM_RE.findall(v))
        elif isinstance(v, dict):
            _collect_params_from(cast(dict[str, Any], v), out)


# --- YAML (F14) ----------------------------------------------------------


def compile_to_yaml(topo: Topology, path: Any) -> None:
    """Serialise ``topo`` to YAML at ``path`` per spec §6.3.

    Deterministic key order: schema_version, name, params, ports, nodes,
    edges. Optional node fields (adapter, params, depends_on, init_directive)
    are omitted when empty to keep diffs minimal.
    """
    import yaml

    doc: dict[str, Any] = {
        "schema_version": 1,
        "name": topo.name,
        "params": list(topo.params),
        "ports": {
            "in": dict(topo.ports_in),
            "out": dict(topo.ports_out),
        },
        "nodes": [_node_to_dict(n) for n in topo.nodes],
        "edges": [list(e) for e in topo.edges],
    }
    text = yaml.safe_dump(doc, sort_keys=False, default_flow_style=False, allow_unicode=True)
    # Accept both str and PathLike
    from pathlib import Path as _Path

    _Path(path).write_text(text, encoding="utf-8")


def _node_to_dict(n: _Node) -> dict[str, Any]:
    """Serialise a ``_Node`` to a YAML-friendly dict with stable key order."""
    out: dict[str, Any] = {
        "id": n.id,
        "actor_type": n.actor_type,
        "handler": n.handler,
    }
    if n.adapter is not None:
        out["adapter"] = n.adapter
    if n.params:
        out["params"] = dict(n.params)
    if n.depends_on:
        out["depends_on"] = list(n.depends_on)
    if n.init_directive:
        out["init_directive"] = dict(n.init_directive)
    return out
