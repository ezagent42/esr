"""IPC plumbing shared by adapter sidecars and handler_worker.

The ``_adapter_common`` package hosts adapter-dispatch specifics
(directive loop, event loop, adapter loader). Anything used by BOTH
the adapter side and the handler side — URL resolution against the
runtime port file, reconnect backoff schedule, disconnect watcher —
lives here.

Package layout:
  - :mod:`_ipc_common.url`        — port-file-aware URL resolution.
  - :mod:`_ipc_common.reconnect`  — exponential backoff schedule.
  - :mod:`_ipc_common.disconnect` — cancellable WS disconnect watcher (arriving in P5-3).
"""
