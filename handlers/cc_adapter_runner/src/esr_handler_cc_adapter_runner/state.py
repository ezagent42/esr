"""cc_adapter_runner state (PR-9 T11a placeholder)."""

from __future__ import annotations

from pydantic import BaseModel

from esr import handler_state


@handler_state(actor_type="cc_adapter_runner", schema_version=1)
class CcAdapterRunnerState(BaseModel):
    """State carried between CCProcess handler invocations.

    Minimal for the placeholder — just counts how many user messages
    we've seen so the e2e ack is distinguishable on re-runs. T11b
    replaces this with whatever state the real CC pipeline needs
    (probably just parent_thread + maybe last_prompt_id).
    """

    model_config = {"frozen": True}

    message_count: int = 0
