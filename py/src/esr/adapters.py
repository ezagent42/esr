"""Adapter factory loader (Phase 8a/8b).

Adapter packages ship as ``esr_<name>`` (e.g. ``esr_feishu``,
``esr_cc_mcp``). Importing the package triggers ``@adapter(name=...)``
registration into :data:`esr.adapter.ADAPTER_REGISTRY`. This module
exposes a single function, :func:`load_adapter_factory`, that takes a
name string and returns the adapter class's ``factory`` staticmethod.
"""
from __future__ import annotations

import importlib
from collections.abc import Callable
from typing import Any

from esr.adapter import ADAPTER_REGISTRY


class AdapterNotFound(LookupError):
    """Raised when no adapter with the requested name is registered."""


def load_adapter_factory(name: str) -> Callable[..., Any]:
    """Import ``esr_<name>`` and return the registered adapter's factory.

    Name normalisation: hyphens in ``name`` become underscores in the
    package (``cc-mcp`` → ``esr_cc_mcp``). If the package cannot be
    imported OR the registry does not contain ``name`` after import,
    :class:`AdapterNotFound` is raised with the looked-up package path
    so operators can diagnose.
    """
    pkg_name = f"esr_{name.replace('-', '_')}"
    if name not in ADAPTER_REGISTRY:
        try:
            importlib.import_module(pkg_name)
        except ImportError as exc:
            raise AdapterNotFound(
                f"adapter {name!r}: package {pkg_name!r} not importable ({exc})"
            ) from exc
    entry = ADAPTER_REGISTRY.get(name)
    if entry is None:
        raise AdapterNotFound(
            f"adapter {name!r}: not in ADAPTER_REGISTRY after importing {pkg_name!r}"
        )
    factory = entry.cls.__dict__.get("factory")
    if factory is None:
        raise AdapterNotFound(
            f"adapter {name!r}: class {entry.cls.__name__} has no factory staticmethod"
        )
    # staticmethod → unwrap to the underlying function
    if isinstance(factory, staticmethod):
        factory = factory.__func__
    return factory
