"""tmux-proxy state model (PRD 05 F15)."""

from __future__ import annotations

from pydantic import BaseModel

from esr import handler_state


@handler_state(actor_type="tmux_proxy", schema_version=1)
class TmuxProxyState(BaseModel):
    """State for a tmux_proxy actor — only needs the session name."""

    model_config = {"frozen": True}

    session_name: str = ""
