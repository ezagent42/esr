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

Mutation of any Action instance raises — frozen dataclasses are the
only shape of value type in the SDK.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Emit:
    """Directive to an adapter instance (§4.4)."""

    adapter: str
    action: str
    args: dict[str, Any]


@dataclass(frozen=True)
class Route:
    """Message to another actor in this esrd instance (§4.4)."""

    target: str
    msg: Any


@dataclass(frozen=True)
class InvokeCommand:
    """Instantiate a registered command (§4.4, §6.5)."""

    name: str
    params: dict[str, Any]


Action = Emit | Route | InvokeCommand
"""Type alias — the full set of shapes a handler may return."""
