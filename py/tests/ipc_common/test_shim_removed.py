"""After PR-5 P5-5, ``esr.ipc.adapter_runner`` no longer exists.

Keeps us honest: the deprecation window is closed, the shim is gone,
and importing it must fail with ModuleNotFoundError (not a silent
pass-through to some lingering package).
"""
from __future__ import annotations

import pytest


def test_shim_module_removed() -> None:
    with pytest.raises(ModuleNotFoundError) as excinfo:
        import esr.ipc.adapter_runner  # noqa: F401
    assert excinfo.value.name == "esr.ipc.adapter_runner", (
        f"expected ModuleNotFoundError for 'esr.ipc.adapter_runner' specifically; "
        f"got {excinfo.value.name!r} — is the shim being re-introduced by accident?"
    )
