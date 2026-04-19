"""Mock Feishu (Lark) HTTP server — Phase 8d.

Emulates the two Lark Open API endpoints the CLI's final_gate.sh --mock
path uses:

- POST ``/open-apis/im/v1/messages`` — bot sends a message into a chat;
  mock returns a Lark-shaped reply and records the call for test
  assertions.
- GET ``/open-apis/im/v1/messages`` — list messages in a chat, sorted
  newest-first (server-side L4 verification query).

A WebSocket endpoint for inbound ``P2ImMessageReceiveV1`` events lands
in a later iter.

Usage as a library (tests):

    mock = MockFeishu()
    url = await mock.start()     # returns ``http://127.0.0.1:<port>``
    ...
    await mock.stop()

Usage standalone (from final_gate.sh --mock):

    uv run --project py python scripts/mock_feishu.py --port 8101
"""
from __future__ import annotations

import argparse
import asyncio
import json
import secrets
import sys
import time
from typing import Any

from aiohttp import web


def _new_message_id() -> str:
    return "om_mock_" + secrets.token_hex(8)


class MockFeishu:
    """In-process mock for Lark Open API endpoints used by ESR v0.1."""

    def __init__(self) -> None:
        self._sent_messages: list[dict[str, Any]] = []
        # per-chat history — newest-first order for each list
        self._chat_history: dict[str, list[dict[str, Any]]] = {}
        self._runner: web.AppRunner | None = None
        self._site: web.TCPSite | None = None
        self._port: int | None = None
        # connected WS clients — the feishu adapter opens one of these
        self._ws_clients: list[web.WebSocketResponse] = []

    # -- public API -----------------------------------------------------

    @property
    def sent_messages(self) -> list[dict[str, Any]]:
        return list(self._sent_messages)

    def seed_inbound_message(
        self,
        *,
        chat_id: str,
        sender_type: str = "user",
        msg_type: str = "text",
        content_text: str = "",
    ) -> str:
        """Register a test-inbound message (as if a real user posted it)."""
        msg_id = _new_message_id()
        content = json.dumps({"text": content_text}, ensure_ascii=False)
        entry = {
            "message_id": msg_id,
            "create_time": str(int(time.time() * 1000)),
            "chat_id": chat_id,
            "msg_type": msg_type,
            "sender": {"sender_type": sender_type, "sender_id": {"open_id": "ou_test"}},
            "body": {"content": content},
        }
        self._chat_history.setdefault(chat_id, []).insert(0, entry)
        return msg_id

    async def start(self, *, port: int = 0) -> str:
        app = web.Application()
        app.router.add_post("/open-apis/im/v1/messages", self._on_create_message)
        app.router.add_get("/open-apis/im/v1/messages", self._on_list_messages)
        app.router.add_get("/ws", self._on_ws_connect)

        self._runner = web.AppRunner(app)
        await self._runner.setup()
        self._site = web.TCPSite(self._runner, "127.0.0.1", port)
        await self._site.start()
        sockets = self._site._server.sockets  # type: ignore[union-attr]
        self._port = sockets[0].getsockname()[1]
        return f"http://127.0.0.1:{self._port}"

    async def stop(self) -> None:
        for ws in self._ws_clients:
            if not ws.closed:
                await ws.close()
        self._ws_clients.clear()
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None
            self._site = None
            self._port = None

    def push_inbound(
        self,
        *,
        chat_id: str,
        sender_open_id: str,
        msg_type: str = "text",
        content_text: str = "",
    ) -> str:
        """Synthesize a P2ImMessageReceiveV1 envelope and push it to every
        connected WS client. Returns the synthesised message_id."""
        msg_id = _new_message_id()
        envelope = {
            "schema": "2.0",
            "header": {
                "event_id": secrets.token_hex(16),
                "event_type": "im.message.receive_v1",
                "create_time": str(int(time.time() * 1000)),
                "token": "",
                "app_id": "cli_mock",
            },
            "event": {
                "sender": {
                    "sender_id": {"open_id": sender_open_id},
                    "sender_type": "user",
                },
                "message": {
                    "message_id": msg_id,
                    "chat_id": chat_id,
                    "chat_type": "p2p",
                    "message_type": msg_type,
                    "create_time": str(int(time.time() * 1000)),
                    "content": json.dumps({"text": content_text}, ensure_ascii=False),
                },
            },
        }
        data = json.dumps(envelope, ensure_ascii=False)
        for ws in list(self._ws_clients):
            if not ws.closed:
                # Schedule the send without awaiting — callers use this
                # from sync test code.
                asyncio.create_task(ws.send_str(data))  # noqa: RUF006
        return msg_id

    # -- handlers -------------------------------------------------------

    async def _on_create_message(self, request: web.Request) -> web.Response:
        """POST /open-apis/im/v1/messages — bot sends a message to a chat."""
        body = await request.json()
        message_id = _new_message_id()

        record = {
            "message_id": message_id,
            "receive_id_type": request.query.get("receive_id_type", "chat_id"),
            "receive_id": body.get("receive_id"),
            "msg_type": body.get("msg_type"),
            "content": body.get("content"),
            "ts_unix_ms": int(time.time() * 1000),
        }
        self._sent_messages.append(record)

        chat_id = body.get("receive_id") or "unknown"
        entry = {
            "message_id": message_id,
            "create_time": str(record["ts_unix_ms"]),
            "chat_id": chat_id,
            "msg_type": body.get("msg_type"),
            "sender": {"sender_type": "app", "sender_id": {"open_id": "ou_mock_bot"}},
            "body": {"content": body.get("content")},
        }
        self._chat_history.setdefault(chat_id, []).insert(0, entry)

        return web.json_response({
            "code": 0,
            "msg": "",
            "data": {"message_id": message_id},
        })

    async def _on_ws_connect(self, request: web.Request) -> web.WebSocketResponse:
        """GET /ws upgrade — adapter subscribes here for inbound events."""
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self._ws_clients.append(ws)
        try:
            async for _msg in ws:  # keep the connection open; discard inbound
                pass
        finally:
            if ws in self._ws_clients:
                self._ws_clients.remove(ws)
        return ws

    async def _on_list_messages(self, request: web.Request) -> web.Response:
        """GET /open-apis/im/v1/messages — list chat history."""
        chat_id = request.query.get("container_id")
        page_size = int(request.query.get("page_size", "20"))
        history = self._chat_history.get(chat_id or "", [])
        items = history[:page_size]
        # Already stored newest-first; no resort needed for "ByCreateTimeDesc".
        return web.json_response({
            "code": 0,
            "msg": "",
            "data": {"items": items, "has_more": len(history) > page_size},
        })


async def _standalone(port: int) -> None:
    mock = MockFeishu()
    url = await mock.start(port=port)
    sys.stdout.write(f"mock-feishu listening at {url}\n")
    sys.stdout.flush()
    try:
        await asyncio.Event().wait()  # run until killed
    finally:
        await mock.stop()


def main() -> int:
    p = argparse.ArgumentParser(description="Mock Feishu Open API server.")
    p.add_argument("--port", type=int, default=8101)
    args = p.parse_args()
    try:
        asyncio.run(_standalone(args.port))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
