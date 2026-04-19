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

import asyncio
import json
import logging
from collections.abc import Callable
from pathlib import Path
from typing import Any

from esr.adapter import AdapterConfig, adapter

logger = logging.getLogger(__name__)

_BACKOFF_SCHEDULE: tuple[float, ...] = (1.0, 2.0, 4.0, 8.0, 16.0, 30.0)
"""Exponential backoff between 429 retries (PRD 04 F15). Total budget 30s."""

_RETRY_DEADLINE_S: float = 30.0
"""Wall-clock ceiling for all combined retry delays (spec §7.3)."""


def _lark_error(response: Any) -> str:
    """Extract a human-readable error from a failing lark_oapi response."""
    return (
        getattr(response, "msg", "")
        or getattr(response, "error", "")
        or ""
    )


def _lark_failure(response: Any, default_msg: str) -> dict[str, Any]:
    """Shape a failing lark response into a directive ack, carrying the code."""
    return {
        "ok": False,
        "error": _lark_error(response) or default_msg,
        "code": getattr(response, "code", 0),
    }


def _is_rate_limited(ack: dict[str, Any]) -> bool:
    """True if the ack's embedded HTTP code indicates a Lark 429."""
    return ack.get("code") == 429


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
            return await self._with_ratelimit_retry(lambda: self._send_message(args))
        if action == "react":
            return await self._with_ratelimit_retry(lambda: self._react(args))
        if action == "send_card":
            return await self._with_ratelimit_retry(lambda: self._send_card(args))
        if action == "pin":
            return await self._with_ratelimit_retry(lambda: self._pin(args))
        if action == "unpin":
            return await self._with_ratelimit_retry(lambda: self._unpin(args))
        if action == "download_file":
            return self._download_file(args)
        return {"ok": False, "error": f"unknown action: {action}"}

    async def _with_ratelimit_retry(
        self, fn: Callable[[], dict[str, Any]]
    ) -> dict[str, Any]:
        """Run ``fn`` and transparently retry on 429 per PRD 04 F15.

        Non-429 failures surface immediately. Retry delays follow an
        exponential schedule; cumulative sleep cannot exceed
        ``_RETRY_DEADLINE_S`` — once the next backoff would cross the
        ceiling, returns ``{"ok": False, "error": "timeout"}``.
        """
        elapsed = 0.0
        for delay in _BACKOFF_SCHEDULE:
            result = fn()
            if result.get("ok") or not _is_rate_limited(result):
                return result
            if elapsed + delay > _RETRY_DEADLINE_S:
                return {"ok": False, "error": "timeout"}
            await asyncio.sleep(delay)
            elapsed += delay
        # Final attempt after the last scheduled sleep
        result = fn()
        if result.get("ok") or not _is_rate_limited(result):
            return result
        return {"ok": False, "error": "timeout"}

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
        return _lark_failure(response, "send failed")

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
        return _lark_failure(response, "react failed")

    def _send_card(self, args: dict[str, Any]) -> dict[str, Any]:
        """Send an interactive card via lark_oapi im.v1.message.create (PRD 04 F09)."""
        import lark_oapi.api.im.v1 as im_v1

        chat_id = args["chat_id"]
        card = args["card"]
        request = (
            im_v1.CreateMessageRequest.builder()
            .receive_id_type("chat_id")
            .request_body(
                im_v1.CreateMessageRequestBody.builder()
                .receive_id(chat_id)
                .msg_type("interactive")
                .content(json.dumps(card))
                .build()
            )
            .build()
        )
        response = self.client().im.v1.message.create(request)
        if response.success():
            return {"ok": True, "result": {"message_id": response.data.message_id}}
        return _lark_failure(response, "send_card failed")

    def _pin(self, args: dict[str, Any]) -> dict[str, Any]:
        """Pin a message via lark_oapi im.v1.pin.create (PRD 04 F10)."""
        import lark_oapi.api.im.v1 as im_v1

        msg_id = args["msg_id"]
        request = (
            im_v1.CreatePinRequest.builder()
            .request_body(im_v1.Pin.builder().message_id(msg_id).build())
            .build()
        )
        response = self.client().im.v1.pin.create(request)
        if response.success():
            return {"ok": True}
        return _lark_failure(response, "pin failed")

    def _unpin(self, args: dict[str, Any]) -> dict[str, Any]:
        """Unpin a message via lark_oapi im.v1.pin.delete (PRD 04 F10)."""
        import lark_oapi.api.im.v1 as im_v1

        msg_id = args["msg_id"]
        request = im_v1.DeletePinRequest.builder().message_id(msg_id).build()
        response = self.client().im.v1.pin.delete(request)
        if response.success():
            return {"ok": True}
        return _lark_failure(response, "unpin failed")

    def _download_file(self, args: dict[str, Any]) -> dict[str, Any]:
        """Download a message's file/image/audio to the uploads dir (PRD 04 F14).

        Layout: <uploads_dir>/<chat_id>/<file_name>. The uploads_dir is
        taken from AdapterConfig.uploads_dir (falling back to
        ~/.esrd/<instance>/uploads).
        """
        import lark_oapi.api.im.v1 as im_v1

        msg_id = args["msg_id"]
        file_key = args["file_key"]
        file_name = args["file_name"]
        msg_type = args["msg_type"]
        chat_id = args["chat_id"]

        request = (
            im_v1.GetMessageResourceRequest.builder()
            .message_id(msg_id)
            .file_key(file_key)
            .type(msg_type)
            .build()
        )
        response = self.client().im.v1.message_resource.get(request)
        if not response.success():
            return _lark_failure(response, "download failed")

        uploads_dir = self._uploads_dir()
        target = uploads_dir / chat_id / file_name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(response.file.read())
        return {"ok": True, "result": {"path": str(target)}}

    def _uploads_dir(self) -> Path:
        """Resolve the uploads directory — config override or the default."""
        configured = getattr(self._config, "uploads_dir", None) if (
            hasattr(self._config, "uploads_dir")
        ) else None
        if configured:
            return Path(configured)
        return Path.home() / ".esrd" / "default" / "uploads"
