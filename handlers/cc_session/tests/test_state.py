"""PRD 05 F17 — cc_session state."""

from __future__ import annotations

import pytest
from pydantic import ValidationError


def test_defaults_and_frozen() -> None:
    from esr_handler_cc_session.state import CcSessionState

    s = CcSessionState()
    assert s.session_name == ""
    assert s.parent_thread == ""
    assert s.pending_outputs == ()
    with pytest.raises(ValidationError):
        s.session_name = "x"  # type: ignore[misc]
