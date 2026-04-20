from __future__ import annotations

from pydantic import BaseModel

from esr import handler_state


@handler_state(actor_type="feishu_app_proxy", schema_version=1)
class FeishuAppState(BaseModel):
    """State for a feishu_app_proxy actor."""

    model_config = {"frozen": True}

    app_id: str = ""
    bound_threads: frozenset[str] = frozenset()
    active_thread_by_chat: dict[str, str] = {}
    last_chat_id: str = ""

    def with_added_thread(self, thread_id: str) -> FeishuAppState:
        return self.model_copy(
            update={"bound_threads": self.bound_threads | {thread_id}}
        )

    def with_active_thread(self, chat_id: str, thread_id: str) -> FeishuAppState:
        updated = dict(self.active_thread_by_chat)
        updated[chat_id] = thread_id
        return self.model_copy(update={"active_thread_by_chat": updated})

    def with_last_chat_id(self, chat_id: str) -> FeishuAppState:
        return self.model_copy(update={"last_chat_id": chat_id})
