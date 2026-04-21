"""Handler + state decorators and registries (PRD 02 F04 / F05 / F06).

`@esr.handler(actor_type=..., name=...)` registers a pure function
under the key ``f"{actor_type}.{name}"`` in the module-level
``HANDLER_REGISTRY``. `@esr.handler_state(actor_type=..., schema_version=...)`
registers the associated pydantic state model under ``actor_type`` in
``STATE_REGISTRY`` — there is at most one state model per actor_type.

Both decorators return the decorated object unchanged so that
handler functions remain directly invocable and state models remain
directly usable (instantiation, validation) in unit tests.

Registries are plain mutable dicts. ``HANDLER_REGISTRY.clear()`` /
``STATE_REGISTRY.clear()`` are the intended cleanup path for tests —
see PRD 02 F06.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from pydantic import BaseModel

HandlerFn = Callable[..., Any]


@dataclass(frozen=True)
class HandlerEntry:
    """A registered handler. See PRD 02 F04 / F06.

    ``permissions`` is the set of action-name strings this handler
    implements (capabilities spec §3.1). Declared via the optional
    ``permissions=[...]`` kwarg on ``@handler``; default is empty.
    """

    actor_type: str
    name: str
    fn: HandlerFn
    permissions: frozenset[str] = frozenset()


@dataclass(frozen=True)
class StateEntry:
    """A registered state model. See PRD 02 F05 / F06."""

    actor_type: str
    schema_version: int
    model: type[BaseModel]


HANDLER_REGISTRY: dict[str, HandlerEntry] = {}
"""Global handler registry — key is ``f"{actor_type}.{name}"``."""

STATE_REGISTRY: dict[str, StateEntry] = {}
"""Global state-model registry — key is ``actor_type``."""


def handler(
    *,
    actor_type: str,
    name: str,
    permissions: list[str] | None = None,
) -> Callable[[HandlerFn], HandlerFn]:
    """Register a handler function under ``actor_type.name``.

    Returns the original callable so the decorated function remains
    usable directly. Duplicate registration raises ``ValueError``.

    ``permissions`` lists the action-name strings this handler
    implements (capabilities spec §3.1). Stored on the HandlerEntry
    as a frozenset; aggregated across the registry by
    :func:`all_permissions` and shipped to the Elixir runtime in the
    ``handler_hello`` IPC envelope at worker startup (spec §4.1).
    """

    def decorate(fn: HandlerFn) -> HandlerFn:
        key = f"{actor_type}.{name}"
        if key in HANDLER_REGISTRY:
            raise ValueError(f"handler {key} already registered")
        HANDLER_REGISTRY[key] = HandlerEntry(
            actor_type=actor_type,
            name=name,
            fn=fn,
            permissions=frozenset(permissions or []),
        )
        return fn

    return decorate


def all_permissions() -> frozenset[str]:
    """Union of every registered handler's permissions (spec §3.1).

    Used by ``esr.ipc.adapter_runner`` / ``handler_worker`` to emit
    the ``handler_hello`` envelope payload that tells the Elixir
    runtime which permission strings this Python process declares.
    """
    return frozenset().union(*(e.permissions for e in HANDLER_REGISTRY.values()))


def handler_state(
    *, actor_type: str, schema_version: int
) -> Callable[[type[BaseModel]], type[BaseModel]]:
    """Register a frozen pydantic state model for ``actor_type``.

    The model must have ``model_config`` containing ``frozen=True``;
    otherwise registration fails with ``TypeError``. At most one
    state model per actor_type — duplicate registration raises
    ``ValueError``.
    """

    def decorate(cls: type[BaseModel]) -> type[BaseModel]:
        if not _is_frozen_model(cls):
            raise TypeError(
                f"state model for {actor_type} must be frozen "
                "(set model_config['frozen'] = True)"
            )
        if actor_type in STATE_REGISTRY:
            raise ValueError(f"state for {actor_type} already registered")
        STATE_REGISTRY[actor_type] = StateEntry(
            actor_type=actor_type, schema_version=schema_version, model=cls
        )
        return cls

    return decorate


def _is_frozen_model(cls: type[BaseModel]) -> bool:
    """True iff the pydantic model has ``frozen=True`` in its config."""
    cfg = getattr(cls, "model_config", None)
    if isinstance(cfg, dict):
        return bool(cfg.get("frozen", False))
    return bool(getattr(cfg, "frozen", False))
