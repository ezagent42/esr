"""Handler-returnable Action types. Spec §4.4, PRD 02 F02.

Handlers return a tuple `(new_state, [Action])`. v0.1 recognises three
action shapes:

- `Emit(adapter, action, args)` — instruct the runtime to issue a
  directive on `adapter` with the named action.
- `Route(target, msg)` — deliver `msg` to another actor within the
  same esrd instance.
- `InvokeCommand(name, params)` — instantiate a registered command
  (sub-topology) with the given params. Same mechanism as CLI
  `esr cmd run <name>`; used e.g. by `feishu_app.on_msg` on
  `/new-thread <foo>`.

Frozen at every level: the dataclass wrapper blocks attribute
assignment and ``__post_init__`` wraps the dict payloads in
``MappingProxyType`` so callers can't mutate the inner dict and
break equality / hashability invariants (reviewer S1).
"""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Any


@dataclass(frozen=True)
class Emit:
    """Directive to an adapter instance (§4.4)."""

    adapter: str
    action: str
    args: MappingProxyType[str, Any]

    def __init__(self, *, adapter: str, action: str, args: dict[str, Any]) -> None:
        object.__setattr__(self, "adapter", adapter)
        object.__setattr__(self, "action", action)
        object.__setattr__(self, "args", MappingProxyType(dict(args)))


@dataclass(frozen=True)
class Route:
    """Message to another actor in this esrd instance (§4.4)."""

    target: str
    msg: Any


@dataclass(frozen=True)
class InvokeCommand:
    """Instantiate a registered command (§4.4, §6.5)."""

    name: str
    params: MappingProxyType[str, Any]

    def __init__(self, *, name: str, params: dict[str, Any]) -> None:
        object.__setattr__(self, "name", name)
        object.__setattr__(self, "params", MappingProxyType(dict(params)))


Action = Emit | Route | InvokeCommand
"""Type alias — the full set of shapes a handler may return."""
