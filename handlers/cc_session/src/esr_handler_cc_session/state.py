"""cc_session state model (PRD 05 F17)."""

from __future__ import annotations

from pydantic import BaseModel

from esr import handler_state


@handler_state(actor_type="cc_proxy", schema_version=1)
class CcSessionState(BaseModel):
    """State for a cc_proxy actor — knows its CC session + parent thread."""

    model_config = {"frozen": True}

    session_name: str = ""
    parent_thread: str = ""
    pending_outputs: tuple[str, ...] = ()
