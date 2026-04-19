"""PRD 04 F22 — cc_tmux environment check (missing tmux)."""

from __future__ import annotations

from typing import Any
from unittest.mock import patch

import pytest

from esr.adapter import AdapterConfig
from esr_cc_tmux.adapter import CcTmuxAdapter


@pytest.fixture
def adapter_instance() -> CcTmuxAdapter:
    cfg = AdapterConfig({})
    return CcTmuxAdapter.factory(actor_id="cc_tmux:t1", config=cfg)


async def test_on_directive_without_tmux_returns_error(
    adapter_instance: CcTmuxAdapter,
) -> None:
    """When ``tmux --version`` raises FileNotFoundError, every directive
    returns a graceful ``{"ok": False, "error": "tmux not installed"}``
    instead of crashing (F22).
    """
    with patch(
        "esr_cc_tmux.adapter.subprocess.run",
        side_effect=FileNotFoundError("tmux: command not found"),
    ):
        reply = await adapter_instance.on_directive(
            "new_session", {"session_name": "foo", "start_cmd": "/bin/true"}
        )

    assert reply == {"ok": False, "error": "tmux not installed"}


async def test_missing_tmux_probe_cached(
    adapter_instance: CcTmuxAdapter,
) -> None:
    """Factory stays pure (no probe); first directive probes; later
    directives use the cached False and don't reprobe subprocess.
    """
    call_count = 0

    def track_and_fail(*_args: Any, **_kwargs: Any) -> Any:
        nonlocal call_count
        call_count += 1
        raise FileNotFoundError

    with patch("esr_cc_tmux.adapter.subprocess.run", side_effect=track_and_fail):
        # Two directives — first probes, second uses the cached miss.
        r1 = await adapter_instance.on_directive(
            "send_keys", {"session_name": "a", "content": "x"}
        )
        r2 = await adapter_instance.on_directive(
            "kill_session", {"session_name": "a"}
        )

    assert r1["ok"] is False
    assert r2["ok"] is False
    # Only one probe. Directive-level subprocess calls never happened
    # because the probe cached False.
    assert call_count == 1
