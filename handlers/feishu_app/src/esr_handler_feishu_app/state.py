"""Feishu app-proxy state model (PRD 05 F06).

One instance per bound Feishu app — holds the set of thread_ids that
have been spun up via ``/new-thread``. The set stays bounded in
practice because threads are expected to close after their parent CC
session exits; v0.1 does not prune the set automatically (a small
leak; acceptable for single-tenant dev use).
"""

from __future__ import annotations

from pydantic import BaseModel

from esr import handler_state


@handler_state(actor_type="feishu_app_proxy", schema_version=1)
class FeishuAppState(BaseModel):
    """State for a feishu_app_proxy actor."""

    model_config = {"frozen": True}

    app_id: str = ""
    bound_threads: frozenset[str] = frozenset()

    def with_added_thread(self, thread_id: str) -> FeishuAppState:
        """Return a new state with ``thread_id`` added to ``bound_threads``."""
        return self.model_copy(
            update={"bound_threads": self.bound_threads | {thread_id}}
        )
