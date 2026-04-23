"""Shared helpers for per-adapter-type sidecars (PR-4b).

The three per-type sidecars (:mod:`feishu_adapter_runner`,
:mod:`cc_adapter_runner`, :mod:`generic_adapter_runner`) all share the
same core dispatch machinery — directive/event loops, WS reconnect with
port-file re-read, and CLI-argument parsing. Those helpers live here so
each sidecar is reduced to ~25 lines of glue:

* :mod:`_adapter_common.runner_core` — ``process_directive``,
  ``directive_loop``, ``event_loop``, ``run_with_client``,
  ``_watch_disconnect``, ``run_with_reconnect``, and ``run`` (the
  factory-loading orchestration entry point).
* :mod:`_adapter_common.main` — ``build_main(allowed_adapters=..., prog=...)``
  factory. Each per-type sidecar wires its own allowlist + program name
  and exposes the returned ``main`` callable as ``__main__``.

Note: URL resolution (``resolve_url``) and reconnect backoff schedule
were moved to :mod:`_ipc_common` in P5-2.

Historical note: these helpers were extracted from the former
``esr.ipc.adapter_runner`` monolith; that shim has been deleted in
PR-5. ``_adapter_common`` is now the authoritative home for the
shared dispatch machinery — there is no longer a compatibility
re-export layer.
"""
