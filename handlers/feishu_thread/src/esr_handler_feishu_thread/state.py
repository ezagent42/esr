"""Feishu thread-proxy state model (PRD 05 F10 / F11).

One instance per Feishu thread bound to a CC session. Tracks:
 - ``thread_id`` — the Feishu thread identifier (set at spawn time by
   the pattern's ``init_directive``)
 - ``dedup`` — bounded set of seen msg_ids (PRD 05 F11) so re-delivered
   events don't get double-acked
 - ``ack_msg_id`` — last acked msg (informational)
 - ``chat_id`` — the Feishu chat this thread belongs to; stored on
   first inbound message for use in outbound send_message (F13)

``dedup`` is capped at 1000 entries. The ``frozenset`` field holds
membership; ``dedup_order`` holds insertion order so ``with_added_dedup``
can drop the oldest entry when at cap.
"""

from __future__ import annotations

from pydantic import BaseModel

from esr import handler_state

_DEDUP_CAP = 1000


@handler_state(actor_type="feishu_thread_proxy", schema_version=1)
class FeishuThreadState(BaseModel):
    """State for a feishu_thread_proxy actor."""

    model_config = {"frozen": True}

    thread_id: str = ""
    chat_id: str = ""
    dedup: frozenset[str] = frozenset()
    dedup_order: tuple[str, ...] = ()
    ack_msg_id: str | None = None

    def with_added_dedup(self, msg_id: str) -> FeishuThreadState:
        """Record ``msg_id`` as seen; drop oldest if at cap."""
        if msg_id in self.dedup:
            return self
        new_order = self.dedup_order + (msg_id,)
        new_dedup = self.dedup | {msg_id}
        if len(new_order) > _DEDUP_CAP:
            oldest, *rest = new_order
            new_order = tuple(rest)
            new_dedup = new_dedup - {oldest}
        return self.model_copy(update={"dedup": new_dedup, "dedup_order": new_order})

    def with_chat_id(self, chat_id: str) -> FeishuThreadState:
        return self.model_copy(update={"chat_id": chat_id})

    def with_ack(self, msg_id: str) -> FeishuThreadState:
        return self.model_copy(update={"ack_msg_id": msg_id})
