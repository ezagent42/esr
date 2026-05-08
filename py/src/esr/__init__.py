"""ESR Python SDK — adapter / handler decorators + IPC primitives.

2026-05-06: the topology DSL (`command`, `node`, `port`, `compose`,
`compile_topology`, `compile_to_yaml`) was removed alongside the
P3-13-deleted `Esr.Topology` runtime. Sessions / topologies are
spawned via slash commands (`/new-session`) now; declarative
patterns are no longer the user-authoring surface.

Public surface narrowed to the handler/adapter SDK + the message
shapes (`Emit`, `Route`, etc.) that adapter sidecars produce::

    from esr import handler, adapter, Emit, Route, InvokeCommand

Submodules exist for internal organisation — they are not a stable
surface and may move between versions.
"""

from esr.actions import Action, Emit, InvokeCommand, Reply, Route, SendInput
from esr.adapter import AdapterConfig, adapter
from esr.events import Directive, Event
from esr.handler import handler, handler_state
from esr.uri import EsrURI

__version__ = "0.1.0"

__all__ = [
    "Action",
    "AdapterConfig",
    "Directive",
    "Emit",
    "EsrURI",
    "Event",
    "InvokeCommand",
    "Reply",
    "Route",
    "SendInput",
    "__version__",
    "adapter",
    "handler",
    "handler_state",
]
