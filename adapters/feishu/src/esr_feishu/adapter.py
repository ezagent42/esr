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


def _extract_text(raw_content: str, msg_type: str) -> str:
    """Unwrap the Lark-encoded ``content`` field into a plain string.

    Lark messages of type ``text`` encode the payload as
    ``{"text": "..."}``. Other types (post, image, audio, etc.) use
    distinct schemas we don't decode here — returning the raw content
    preserves diagnostic value without losing information.
    """
    if not raw_content:
        return ""
    if msg_type == "text":
        try:
            parsed = json.loads(raw_content)
        except (ValueError, TypeError):
            return raw_content
        if isinstance(parsed, dict):
            text = parsed.get("text")
            if isinstance(text, str):
                return text
    return raw_content


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

    # --- event emission (PRD 04 F12) ----------------------------------

    async def emit_events(self):  # type: ignore[no-untyped-def]
        """Subscribe to inbound Lark events and yield them as envelope dicts.

        Uses ``lark_oapi.ws.Client`` with a ``p2_im_message_receive_v1``
        handler that pushes onto an asyncio.Queue; the WSClient's
        synchronous ``start()`` runs in a thread executor. The async
        generator yields ``{"event_type": "msg_received", "args": {...}}``
        tuples that adapter_runner.event_loop wraps into envelopes.

        Config fields honoured:
          - ``app_id`` / ``app_secret``: for the WS identity (reused
             from the REST client).
          - ``base_url``: if set to ``http://127.0.0.1:<port>`` or
             ``http://localhost:<port>``, the adapter assumes a
             mock_feishu harness and subscribes to its HTTP SSE / WS
             endpoint instead of the real Lark WS — scenario-friendly.
        """
        base_url = getattr(self._config, "base_url", None) if (
            hasattr(self._config, "base_url")
        ) else None
        if isinstance(base_url, str) and (
            base_url.startswith("http://127.0.0.1")
            or base_url.startswith("http://localhost")
        ):
            async for env in self._emit_events_mock(base_url):
                yield env
            return

        async for env in self._emit_events_lark():
            yield env

    async def _emit_events_lark(self):  # type: ignore[no-untyped-def]
        """Live path — drive lark_oapi.ws.Client and yield received messages."""
        import lark_oapi
        from lark_oapi.event.dispatcher_handler import EventDispatcherHandler

        loop = asyncio.get_running_loop()
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()

        def _handle_receive(data: Any) -> None:
            # data is a P2ImMessageReceiveV1 pydantic-like object. Lark
            # nests the message under data.event.message; we flatten to
            # the minimum the feishu_app handler needs.
            try:
                event = data.event
                message = event.message
                sender = event.sender
                raw_content = getattr(message, "content", "") or ""
                msg_type = getattr(message, "message_type", "") or ""
                # Feishu text messages wrap the body as JSON {"text": "..."}.
                # Handlers work with the plain text (e.g. "/new-thread foo"),
                # so unwrap once at the adapter boundary and keep raw under
                # a separate key for debugging.
                extracted = _extract_text(raw_content, msg_type)
                payload = {
                    "event_type": "msg_received",
                    "args": {
                        "chat_id": getattr(message, "chat_id", "") or "",
                        "message_id": getattr(message, "message_id", "") or "",
                        "content": extracted,
                        "raw_content": raw_content,
                        "msg_type": msg_type,
                        "sender_id": getattr(
                            getattr(sender, "sender_id", None), "open_id", ""
                        ) or "",
                        "sender_type": getattr(sender, "sender_type", "") or "",
                        "thread_id": getattr(message, "thread_id", "") or "",
                        "root_id": getattr(message, "root_id", "") or "",
                    },
                }
                # Schedule enqueue on the loop — callback fires from the
                # WSClient thread so we cross-thread via call_soon_threadsafe.
                loop.call_soon_threadsafe(queue.put_nowait, payload)
            except Exception as exc:  # noqa: BLE001 — callback boundary
                logger.warning("feishu ws callback error: %s", exc)

        handler = (
            EventDispatcherHandler.builder("", "")
            .register_p2_im_message_receive_v1(_handle_receive)
            .build()
        )

        ws_client = lark_oapi.ws.Client(
            self._config.app_id,
            self._config.app_secret,
            event_handler=handler,
        )

        # lark_oapi.ws.Client.start() does loop.run_until_complete on a
        # module-level asyncio event loop captured at import time — that
        # loop IS our running asyncio loop, so start() from an executor
        # thread raises "event loop is already running". Work around by
        # installing a fresh loop on the executor thread AND patching the
        # module-level reference so lark_oapi uses it.
        import lark_oapi.ws.client as _ws_client_mod

        def _run_ws():
            thread_loop = asyncio.new_event_loop()
            asyncio.set_event_loop(thread_loop)
            _ws_client_mod.loop = thread_loop
            ws_client.start()

        ws_task = loop.run_in_executor(None, _run_ws)
        try:
            while True:
                event = await queue.get()
                yield event
        finally:
            # start() has no clean shutdown API in lark_oapi; cancelling
            # the executor future severs the wait, the daemon thread will
            # exit on process teardown.
            ws_task.cancel()

    async def _emit_events_mock(
        self, base_url: str
    ):  # type: ignore[no-untyped-def]
        """Mock path — connect to mock_feishu's ``/ws`` and relay messages.

        mock_feishu.push_inbound emits full P2ImMessageReceiveV1 JSON
        envelopes over its WS. The adapter flattens them to the same
        ``msg_received`` shape the live path yields so downstream
        handlers are adapter-symmetric.
        """
        import aiohttp

        ws_url = base_url.rstrip("/").replace("http://", "ws://") + "/ws"
        async with aiohttp.ClientSession() as session:
            while True:
                try:
                    async with session.ws_connect(
                        ws_url, timeout=aiohttp.ClientWSTimeout(ws_close=30.0)
                    ) as ws:
                        async for msg in ws:
                            if msg.type != aiohttp.WSMsgType.TEXT:
                                continue
                            try:
                                envelope = json.loads(msg.data)
                            except (ValueError, TypeError):
                                continue
                            event = envelope.get("event") or {}
                            message = event.get("message") or {}
                            sender = event.get("sender") or {}
                            sender_id = sender.get("sender_id") or {}
                            raw_content = message.get("content", "")
                            msg_type = message.get("message_type", "")
                            yield {
                                "event_type": "msg_received",
                                "args": {
                                    "chat_id": message.get("chat_id", ""),
                                    "message_id": message.get("message_id", ""),
                                    "content": _extract_text(raw_content, msg_type),
                                    "raw_content": raw_content,
                                    "msg_type": msg_type,
                                    "sender_id": sender_id.get("open_id", ""),
                                    "sender_type": sender.get("sender_type", ""),
                                    "thread_id": message.get("thread_id", ""),
                                    "root_id": message.get("root_id", ""),
                                },
                            }
                except (aiohttp.ClientError, TimeoutError):
                    # mock_feishu restart-tolerance: back off and retry.
                    await asyncio.sleep(1)
