"""Deprecation shim (PR-4b P4b-6) — use the per-type sidecars instead.

``esr.ipc.adapter_runner`` was a 399-line monolith hosting every Python
adapter. PR-4b split it into three per-type sidecars
(:mod:`feishu_adapter_runner`, :mod:`cc_adapter_runner`,
:mod:`generic_adapter_runner`) backed by shared helpers in
:mod:`_adapter_common`. This module re-exports the public surface so
pre-existing imports keep working during the migration window; PR-5
hard-deletes it.
"""
from __future__ import annotations

import warnings

from _adapter_common.main import build_main
from _adapter_common.runner_core import (
    AdapterPusher,
    directive_loop,
    event_loop,
    process_directive,
    run,
    run_with_client,
    run_with_reconnect,
)
from _adapter_common.runner_core import watch_disconnect as _watch_disconnect
from _adapter_common.url import resolve_url as _resolve_url

warnings.warn(
    "esr.ipc.adapter_runner is deprecated; use feishu_adapter_runner, "
    "cc_adapter_runner, or generic_adapter_runner (PR-4b). This shim is "
    "removed in PR-5.",
    DeprecationWarning,
    stacklevel=2,
)


main = build_main(allowed_adapters=None, prog="esr.ipc.adapter_runner")


__all__ = [
    "AdapterPusher",
    "_resolve_url",
    "_watch_disconnect",
    "directive_loop",
    "event_loop",
    "main",
    "process_directive",
    "run",
    "run_with_client",
    "run_with_reconnect",
]


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv[1:]))
