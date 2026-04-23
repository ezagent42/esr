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
* :mod:`_adapter_common.url` — ``_resolve_url`` (re-reads
  ``$ESRD_HOME/$ESR_INSTANCE/esrd.port`` and substitutes into the
  CLI-supplied URL so launchctl kickstart restarts are followed
  seamlessly).
* :mod:`_adapter_common.reconnect` — just re-exports the backoff
  schedule; kept in its own module so the schedule can be tuned in one
  place without touching core.
* :mod:`_adapter_common.main` — ``build_main(allowed_adapters=..., prog=...)``
  factory. Each per-type sidecar wires its own allowlist + program name
  and exposes the returned ``main`` callable as ``__main__``.

Decoupling note: these helpers deliberately do **not** import
``esr.ipc.adapter_runner`` — the relationship is the other way around.
PR-4b's final shim re-exports from here so pre-existing
``from esr.ipc.adapter_runner import run_with_client`` code keeps
working during the migration window.
"""
