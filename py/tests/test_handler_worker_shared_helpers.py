"""handler_worker consumes the shared _ipc_common/ helpers post-P5-4.

Before P5-4, handler_worker.py kept three private copies
(_watch_disconnect, _resolve_url, _RECONNECT_BACKOFF_SCHEDULE). After
P5-4 they all come from _ipc_common/. Import-level smoke that verifies
the module-level attributes resolve to the shared objects, not local ones.
"""
from __future__ import annotations


def test_handler_worker_uses_shared_backoff_schedule() -> None:
    from _ipc_common.reconnect import RECONNECT_BACKOFF_SCHEDULE
    from esr.ipc import handler_worker

    # Post-P5-4, handler_worker either imports the shared constant as
    # _RECONNECT_BACKOFF_SCHEDULE (re-exported) or drops it entirely.
    # Either way, the default argument on run_with_reconnect must
    # resolve to the shared tuple object.
    import inspect

    sig = inspect.signature(handler_worker.run_with_reconnect)
    default = sig.parameters["backoff_schedule"].default
    assert default is RECONNECT_BACKOFF_SCHEDULE, (
        f"handler_worker still uses a private backoff schedule; "
        f"got {default!r}, want {RECONNECT_BACKOFF_SCHEDULE!r}"
    )


def test_handler_worker_uses_shared_watch_disconnect() -> None:
    """The `watch_disconnect` bound inside handler_worker is the shared one."""
    from _ipc_common.disconnect import watch_disconnect
    from esr.ipc import handler_worker

    assert handler_worker.watch_disconnect is watch_disconnect, (
        "handler_worker binds its own _watch_disconnect; it should "
        "`from _ipc_common.disconnect import watch_disconnect` instead"
    )


def test_handler_worker_uses_shared_reconnect_loop() -> None:
    """Post-PR-6 D2, resolve_url lives inside _ipc_common.reconnect_loop;
    handler_worker no longer imports resolve_url directly. Assert on the
    new invariant: the run_with_reconnect wrapper delegates to the shared
    reconnect_loop helper.
    """
    from _ipc_common.reconnect import reconnect_loop
    from esr.ipc import handler_worker

    assert handler_worker.reconnect_loop is reconnect_loop, (
        "handler_worker.run_with_reconnect must delegate to the shared "
        "_ipc_common.reconnect.reconnect_loop helper (PR-6 D2); it should "
        "`from _ipc_common.reconnect import reconnect_loop` at module scope."
    )
