"""Handler decorator + registry (PRD 02 F04).

`@esr.handler(actor_type=..., name=...)` registers a pure function
under the key ``f"{actor_type}.{name}"`` in the module-level
``HANDLER_REGISTRY``. The decorator returns the callable unchanged
so handlers remain directly invocable (important for unit tests —
they call the function with a state + event and assert the
returned ``(new_state, [Action])`` tuple).

Duplicate registration is a hard error. The v0.1 runtime expects
each (actor_type, name) pair to be unique across the loaded
handler packages; collisions indicate a packaging bug that must
surface at import time, not at message-dispatch time.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

HandlerFn = Callable[..., Any]


@dataclass(frozen=True)
class HandlerEntry:
    """A registered handler. See PRD 02 F04 / F06."""

    actor_type: str
    name: str
    fn: HandlerFn


HANDLER_REGISTRY: dict[str, HandlerEntry] = {}
"""Global handler registry — key is ``f"{actor_type}.{name}"``."""


def handler(*, actor_type: str, name: str) -> Callable[[HandlerFn], HandlerFn]:
    """Register a handler function under ``actor_type.name``.

    Returns the original callable so the decorated function remains
    usable directly (tests, composition). Duplicate registration
    raises ``ValueError``.
    """

    def decorate(fn: HandlerFn) -> HandlerFn:
        key = f"{actor_type}.{name}"
        if key in HANDLER_REGISTRY:
            raise ValueError(f"handler {key} already registered")
        HANDLER_REGISTRY[key] = HandlerEntry(actor_type=actor_type, name=name, fn=fn)
        return fn

    return decorate
