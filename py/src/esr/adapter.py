"""Adapter decorator + registry + config (PRD 02 F07 / F08).

`@esr.adapter(name=..., allowed_io={...})` registers an adapter
class in ``ADAPTER_REGISTRY``. The class must expose a ``@staticmethod
factory(actor_id, config) -> <instance>`` — this is the single entry
point the runtime uses to construct an adapter instance when a node
binds it. The decorator returns the class unchanged so it remains
usable for typing / direct construction in tests.

``allowed_io`` is a dict of import-prefix → "*" or a version
constraint. It is recorded here and read by the capability scan
(PRD 02 F18) at CI time — runtime does not enforce it.

``AdapterConfig`` wraps a dict and exposes read-only attribute
access. Setting an attribute raises; missing keys raise
``AttributeError`` (not ``KeyError``) so callers can use
``getattr(cfg, key, default)``. Underscore-prefixed attributes are
never exposed — dunders go to Python's own machinery, and ``_foo``
keys are considered private-by-convention.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class AdapterEntry:
    """A registered adapter. See PRD 02 F07."""

    name: str
    cls: type
    allowed_io: dict[str, Any]


ADAPTER_REGISTRY: dict[str, AdapterEntry] = {}
"""Global adapter registry — key is the adapter's declared ``name``."""


def adapter(
    *, name: str, allowed_io: dict[str, Any]
) -> Callable[[type], type]:
    """Register an adapter class under ``name`` with its I/O manifest."""

    def decorate(cls: type) -> type:
        factory = cls.__dict__.get("factory")
        if not isinstance(factory, staticmethod):
            raise TypeError(
                f"adapter {name} must define a static factory(actor_id, config) method"
            )
        if name in ADAPTER_REGISTRY:
            raise ValueError(f"adapter {name} already registered")
        ADAPTER_REGISTRY[name] = AdapterEntry(
            name=name, cls=cls, allowed_io=dict(allowed_io)
        )
        return cls

    return decorate


class AdapterConfig:
    """Read-only attribute wrapper over a config dict (PRD 02 F08)."""

    __slots__ = ("_data",)

    def __init__(self, data: dict[str, Any]) -> None:
        object.__setattr__(self, "_data", dict(data))

    def __getattr__(self, item: str) -> Any:
        if item.startswith("_"):
            raise AttributeError(item)
        data: dict[str, Any] = object.__getattribute__(self, "_data")
        if item not in data:
            raise AttributeError(f"{item} missing from AdapterConfig")
        return data[item]

    def __setattr__(self, key: str, value: Any) -> None:
        raise AttributeError(f"AdapterConfig is read-only (attempted to set {key})")
