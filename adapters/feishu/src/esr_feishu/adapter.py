"""Feishu adapter entry point (PRD 04 F05-F15).

Registered with the ESR runtime at import time via ``@esr.adapter``.
The factory is deliberately pure (PRD 04 F02): it stores config
and returns an instance — no network calls, no lark_oapi.Client
construction. Actual I/O happens lazily inside ``on_directive`` /
``emit_events``, where errors can be surfaced as directive acks
rather than crashing the process.

Directive/event implementations land in F06+ (lazy lark client,
send_message, react, send_card, pin/unpin, WS listener, rate
limiting). This file currently covers F05 (registration) and the
F02 purity guarantee.
"""

from __future__ import annotations

import json
from typing import Any

from esr.adapter import AdapterConfig, adapter


def _lark_error(response: Any) -> str:
    """Extract a human-readable error from a failing lark_oapi response."""
    return (
        getattr(response, "msg", "")
        or getattr(response, "error", "")
        or ""
    )


@adapter(
    name="feishu",
    allowed_io={
        "lark_oapi": "*",
        "aiohttp": "*",
        "http": ["open.feishu.cn"],
    },
)
class FeishuAdapter:
    """Adapter instance for a single Feishu app identity.

    One instance == one (app_id, app_secret) pair. The runtime may
    register many instances under different names (e.g. a
    ``feishu-shared`` app and a ``feishu-dev`` app) against the same
    adapter class.
    """

    def __init__(self, actor_id: str, config: AdapterConfig) -> None:
        self.actor_id = actor_id
        self._config = config
        self._lark_client: Any | None = None

    @staticmethod
    def factory(actor_id: str, config: AdapterConfig) -> FeishuAdapter:
        """Construct a FeishuAdapter — pure, no I/O (PRD 04 F02)."""
        return FeishuAdapter(actor_id=actor_id, config=config)

    def client(self) -> Any:
        """Return the (cached) ``lark_oapi.Client`` for this adapter.

        Lazy-initialised on first call (PRD 04 F06) so ``factory`` stays pure.
        """
        if self._lark_client is None:
            import lark_oapi

            self._lark_client = (
                lark_oapi.Client.builder()
                .app_id(self._config.app_id)
                .app_secret(self._config.app_secret)
                .build()
            )
        return self._lark_client

    # --- directive dispatch -------------------------------------------

    async def on_directive(
        self, action: str, args: dict[str, Any]
    ) -> dict[str, Any]:
        """Dispatch a directive. Returns {"ok": bool, result?/error?}."""
        if action == "send_message":
            return self._send_message(args)
        if action == "react":
            return self._react(args)
        return {"ok": False, "error": f"unknown action: {action}"}

    def _send_message(self, args: dict[str, Any]) -> dict[str, Any]:
        """Send a text message via lark_oapi im.v1.message.create (PRD 04 F07)."""
        import lark_oapi.api.im.v1 as im_v1

        chat_id = args["chat_id"]
        content = args["content"]
        request = (
            im_v1.CreateMessageRequest.builder()
            .receive_id_type("chat_id")
            .request_body(
                im_v1.CreateMessageRequestBody.builder()
                .receive_id(chat_id)
                .msg_type("text")
                .content(json.dumps({"text": content}))
                .build()
            )
            .build()
        )
        response = self.client().im.v1.message.create(request)
        if response.success():
            return {"ok": True, "result": {"message_id": response.data.message_id}}
        return {"ok": False, "error": _lark_error(response) or "send failed"}

    def _react(self, args: dict[str, Any]) -> dict[str, Any]:
        """Create a reaction on a message via lark_oapi (PRD 04 F08)."""
        import lark_oapi.api.im.v1 as im_v1

        msg_id = args["msg_id"]
        emoji_type = args["emoji_type"]
        request = (
            im_v1.CreateMessageReactionRequest.builder()
            .message_id(msg_id)
            .request_body(
                im_v1.CreateMessageReactionRequestBody.builder()
                .reaction_type(
                    im_v1.Emoji.builder().emoji_type(emoji_type).build()
                )
                .build()
            )
            .build()
        )
        response = self.client().im.v1.message.reaction.create(request)
        if response.success():
            reaction_id = getattr(response.data, "reaction_id", None) or getattr(
                response.data, "message_id", ""
            )
            return {"ok": True, "result": {"reaction_id": reaction_id}}
        return {"ok": False, "error": _lark_error(response) or "react failed"}
