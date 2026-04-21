"""Public API for Python permission declarations (capabilities spec §3.1).

Handlers declare permissions via the ``@handler(permissions=[...])``
decorator in :mod:`esr.handler`; this module re-exports the aggregation
helper so downstream IPC code (``esr.ipc.adapter_runner``,
``esr.ipc.handler_worker``) can import from a stable name.
"""

from esr.handler import all_permissions

__all__ = ["all_permissions"]
