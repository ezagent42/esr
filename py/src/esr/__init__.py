"""ESR v0.1 — Python SDK and CLI.

Public entry points (PRD 02 F19). Users should import from ``esr``
directly rather than from the submodules::

    from esr import handler, adapter, command, node, port, compose, Emit

Submodules exist for internal organisation — they are not a stable
surface and may move between versions.
"""

from esr.actions import Action, Emit, InvokeCommand, Reply, Route, SendInput
from esr.adapter import AdapterConfig, adapter
from esr.command import command, compile_to_yaml, compile_topology, compose, node, port
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
    "command",
    "compile_to_yaml",
    "compile_topology",
    "compose",
    "handler",
    "handler_state",
    "node",
    "port",
]
