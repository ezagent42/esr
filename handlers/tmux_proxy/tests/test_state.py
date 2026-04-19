"""PRD 05 F15 — tmux_proxy state."""

from __future__ import annotations

import pytest
from pydantic import ValidationError


def test_defaults_and_frozen() -> None:
    from esr_handler_tmux_proxy.state import TmuxProxyState

    s = TmuxProxyState()
    assert s.session_name == ""
    with pytest.raises(ValidationError):
        s.session_name = "x"  # type: ignore[misc]
