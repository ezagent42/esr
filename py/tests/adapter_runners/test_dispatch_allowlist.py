"""Parametrised allowlist dispatch coverage (PR-4b P4b-5).

Asserts that each of the three Python sidecars accepts every adapter
name the Elixir-side :mod:`Esr.WorkerSupervisor` dispatch table will
route to it, and rejects every adapter that should land elsewhere.
This is the Python mirror of the Elixir dispatch test — both halves
must agree for the split to be safe.

The parametrised matrix:

=======================  ===========  ===========  ==========
adapter name             feishu_ar    cc_ar        generic_ar
=======================  ===========  ===========  ==========
feishu                   accept (0)   reject (2)   accept (0)
cc_mcp                   reject (2)   accept (0)   accept (0)
new_unknown              reject (2)   reject (2)   accept (0)
=======================  ===========  ===========  ==========

Each row is a pytest case; the test uses ``--dry-run`` so no WebSocket
is opened — the assertion is purely on exit codes driven by allowlist
policy.
"""
from __future__ import annotations

import pytest

from cc_adapter_runner.__main__ import main as cc_main
from feishu_adapter_runner.__main__ import main as feishu_main
from generic_adapter_runner.__main__ import main as generic_main


ACCEPT, REJECT = 0, 2


@pytest.mark.parametrize(
    ("runner", "adapter", "expected"),
    [
        # feishu sidecar: only feishu
        (feishu_main, "feishu", ACCEPT),
        (feishu_main, "cc_mcp", REJECT),
        (feishu_main, "new_unknown", REJECT),
        # cc sidecar: cc_mcp
        (cc_main, "feishu", REJECT),
        (cc_main, "cc_mcp", ACCEPT),
        (cc_main, "new_unknown", REJECT),
        # generic sidecar: accepts everything (no allowlist)
        (generic_main, "feishu", ACCEPT),
        (generic_main, "new_unknown", ACCEPT),
    ],
)
def test_sidecar_allowlist_dispatch(
    runner: object, adapter: str, expected: int
) -> None:
    """Each (sidecar, adapter) pair exits with the allowlist-determined code.

    ``runner`` is the sidecar's ``main`` callable; calling it with
    ``--dry-run`` returns immediately after argv validation, so the
    exit code is a pure allowlist signal.
    """
    exit_code = runner([  # type: ignore[operator]
        "--adapter", adapter,
        "--instance-id", "inst-1",
        "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket",
        "--config-json", "{}",
        "--dry-run",
    ])
    assert exit_code == expected, (
        f"runner={runner.__module__} adapter={adapter!r} "
        f"expected exit {expected}, got {exit_code}"
    )
