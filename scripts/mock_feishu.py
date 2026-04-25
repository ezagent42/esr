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
import base64
import hashlib
import json
import secrets
import sys
import time
from pathlib import Path
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
        # connected WS clients — the adapter opens one of these
        self._ws_clients: list[web.WebSocketResponse] = []
        # reactions + uploaded files (T0 §4)
        self._reactions: list[dict[str, Any]] = []
        # PR-9 T5c: un-reactions, recorded so tests can assert that
        # FeishuChatProxy un-reacted a specific message_id when CC's
        # reply carried `reply_to_message_id`.
        self._un_reactions: list[dict[str, Any]] = []
        self._uploaded_files: list[dict[str, Any]] = []
        self._files_dir: Path | None = None  # set in start()

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
        app.router.add_post(
            "/open-apis/im/v1/messages/{message_id}/reactions",
            self._on_create_reaction,
        )
        # PR-9 T5c: DELETE mirrors Lark Open API
        # `DELETE /open-apis/im/v1/messages/:message_id/reactions/:reaction_id`.
        # For v1 we accept un-react by message_id alone (the scenario
        # helper endpoint below), since FeishuChatProxy tracks reacts
        # by message_id rather than reaction_id — keeps the emit path
        # fire-and-forget without an extra round-trip to fetch the
        # reaction_id. The {reaction_id} path is accepted too so tests
        # that mirror the Lark shape keep working.
        app.router.add_delete(
            "/open-apis/im/v1/messages/{message_id}/reactions/{reaction_id}",
            self._on_delete_reaction_by_id,
        )
        app.router.add_delete(
            "/open-apis/im/v1/messages/{message_id}/reactions",
            self._on_delete_reactions_by_message,
        )
        app.router.add_get("/reactions", self._on_get_reactions)
        app.router.add_get("/un_reactions", self._on_get_un_reactions)
        app.router.add_post("/open-apis/im/v1/files", self._on_upload_file)
        app.router.add_get("/sent_files", self._on_get_sent_files)
        app.router.add_get("/ws", self._on_ws_connect)
        app.router.add_get("/ws_clients", self._on_get_ws_clients)
        app.router.add_post("/push_inbound", self._on_push_inbound)
        app.router.add_get("/sent_messages", self._on_get_sent_messages)

        self._files_dir = Path(f"/tmp/mock-feishu-files-{port or 'rand'}")
        self._files_dir.mkdir(parents=True, exist_ok=True)

        self._runner = web.AppRunner(app)
        await self._runner.setup()
        self._site = web.TCPSite(self._runner, "127.0.0.1", port)
        await self._site.start()
        sockets = self._site._server.sockets  # type: ignore[union-attr]
        self._port = sockets[0].getsockname()[1]
        if self._files_dir.name.endswith("rand"):
            new_dir = Path(f"/tmp/mock-feishu-files-{self._port}")
            # If the target already exists from a prior run, remove it.
            if new_dir.exists():
                for child in new_dir.iterdir():
                    child.unlink()
                new_dir.rmdir()
            self._files_dir.rename(new_dir)
            self._files_dir = new_dir
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
        app_id: str = "cli_mock",
        tenant_key: str = "16a9e2384317175f",
    ) -> str:
        """Synthesize a P2ImMessageReceiveV1 envelope and push it to every
        connected WS client. Returns the synthesised message_id.

        Envelope shape matches adapters/feishu/tests/fixtures/live-capture/
        text_message.json (captured 2026-04-19 against real Feishu Open
        Platform). The Python feishu adapter unpacks header.app_id,
        sender.sender_id.open_id, and message.* — extras vs the live wire
        are safe (lark_oapi ignores them); missing fields cause silent
        drops in consumers, which is what T5 closes.

        T6 will partition routing on `app_id`. T5 just plumbs the value.
        """
        msg_id = _new_message_id()
        now_ms = str(int(time.time() * 1000))
        envelope = {
            "schema": "2.0",
            "header": {
                "event_id": secrets.token_hex(16),
                "token": "",
                "create_time": now_ms,
                "event_type": "im.message.receive_v1",
                "tenant_key": tenant_key,
                "app_id": app_id,
            },
            "event": {
                "sender": {
                    "sender_id": {
                        "user_id": secrets.token_hex(4),
                        "open_id": sender_open_id,
                        "union_id": "on_" + secrets.token_hex(16),
                    },
                    "sender_type": "user",
                    "tenant_key": tenant_key,
                },
                "message": {
                    "message_id": msg_id,
                    "create_time": now_ms,
                    "update_time": now_ms,
                    "chat_id": chat_id,
                    "chat_type": "p2p",
                    "message_type": msg_type,
                    "content": json.dumps({"text": content_text}, ensure_ascii=False),
                    "user_agent": "Mozilla/5.0 (mock_feishu) MockFeishuClient/1.0",
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

        if body.get("msg_type") == "file":
            content = json.loads(body.get("content") or "{}")
            file_key = content.get("file_key", "")
            for entry in self._uploaded_files:
                if entry["file_key"] == file_key and not entry["chat_id"]:
                    entry["chat_id"] = body.get("receive_id", "")
                    break

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

    async def _on_get_ws_clients(self, _request: web.Request) -> web.Response:
        """GET /ws_clients — return the count of connected /ws subscribers.

        Readiness probe for the PR-9 T9 sidecar-ready check: the feishu
        adapter subprocess only opens its ws_connect to /ws after
        Phoenix join + handler_hello succeed, so a non-zero count
        signals the full start-up chain is up and push_inbound will be
        delivered.
        """
        return web.json_response({"count": len(self._ws_clients)})

    async def _on_push_inbound(self, request: web.Request) -> web.Response:
        """POST /push_inbound — scenario helper: inject a Feishu-side
        inbound message as if a user typed it. Body JSON shape:
        {"chat_id": "oc_x", "app_id": "cli_x", "user": "ou_user1",
         "text": "/new-session esr-dev tag=root"}
        """
        body = await request.json()
        msg_id = self.push_inbound(
            chat_id=body.get("chat_id", ""),
            sender_open_id=body.get("user", "ou_test"),
            content_text=body.get("text", ""),
        )
        return web.json_response({"ok": True, "message_id": msg_id})

    async def _on_get_sent_messages(self, request: web.Request) -> web.Response:
        """GET /sent_messages — scenario helper: return the outbound
        message log as a JSON array for grep-style assertions."""
        return web.json_response(list(self._sent_messages))

    async def _on_create_reaction(self, request: web.Request) -> web.Response:
        message_id = request.match_info["message_id"]
        body = await request.json()
        emoji_type = body.get("reaction_type", {}).get("emoji_type", "")
        reaction_id = "rc_mock_" + secrets.token_hex(8)
        self._reactions.append({
            "message_id": message_id,
            "emoji_type": emoji_type,
            "ts_unix_ms": int(time.time() * 1000),
        })
        return web.json_response({
            "code": 0,
            "msg": "",
            "data": {"reaction_id": reaction_id, "message_id": message_id},
        })

    async def _on_get_reactions(self, _request: web.Request) -> web.Response:
        return web.json_response(self._reactions)

    async def _on_delete_reaction_by_id(
        self, request: web.Request
    ) -> web.Response:
        """DELETE /open-apis/im/v1/messages/:message_id/reactions/:reaction_id.

        Mirrors the Lark Open API shape. Records the un-react for test
        assertions; removes any matching reaction from the active list
        so downstream `GET /reactions` no longer surfaces it.
        """
        message_id = request.match_info["message_id"]
        reaction_id = request.match_info["reaction_id"]
        self._un_reactions.append({
            "message_id": message_id,
            "reaction_id": reaction_id,
            "ts_unix_ms": int(time.time() * 1000),
        })
        # Remove the first matching reaction (by message_id), if any.
        for idx, entry in enumerate(self._reactions):
            if entry["message_id"] == message_id:
                self._reactions.pop(idx)
                break
        return web.json_response({"code": 0, "msg": "", "data": {}})

    async def _on_delete_reactions_by_message(
        self, request: web.Request
    ) -> web.Response:
        """DELETE /open-apis/im/v1/messages/:message_id/reactions.

        V1 best-effort un-react: FeishuChatProxy doesn't track
        reaction_ids, so it deletes by message_id. Removes ALL
        reactions on that message and records one un-react entry per
        removed reaction.
        """
        message_id = request.match_info["message_id"]
        body: dict[str, Any] = {}
        if request.can_read_body:
            try:
                body = await request.json()
            except (ValueError, TypeError):
                body = {}
        emoji_type = (body.get("reaction_type") or {}).get("emoji_type", "")

        removed = [r for r in self._reactions if r["message_id"] == message_id]
        self._reactions = [
            r for r in self._reactions if r["message_id"] != message_id
        ]
        for r in removed:
            self._un_reactions.append({
                "message_id": message_id,
                "emoji_type": emoji_type or r.get("emoji_type", ""),
                "ts_unix_ms": int(time.time() * 1000),
            })
        if not removed:
            # Still record the un-react attempt so tests can assert the
            # directive fired even when no live reaction existed (e.g.
            # race where the inbound react hadn't completed yet).
            self._un_reactions.append({
                "message_id": message_id,
                "emoji_type": emoji_type,
                "ts_unix_ms": int(time.time() * 1000),
            })
        return web.json_response({"code": 0, "msg": "", "data": {}})

    async def _on_get_un_reactions(self, _request: web.Request) -> web.Response:
        """GET /un_reactions — scenario helper: return the un-react log."""
        return web.json_response(self._un_reactions)

    async def _on_upload_file(self, request: web.Request) -> web.Response:
        ctype = request.headers.get("content-type", "")
        if "application/json" in ctype:
            body = await request.json()
            file_name = body["file_name"]
            data = base64.b64decode(body["content_b64"])
        else:
            form = await request.post()
            file_name = form["file_name"]
            file_field = form["file"]
            data = file_field.file.read() if hasattr(file_field, "file") else bytes(file_field)

        file_key = "file_mock_" + secrets.token_hex(8)
        assert self._files_dir is not None
        (self._files_dir / file_key).write_bytes(data)
        self._uploaded_files.append({
            "chat_id": "",  # filled on the send-message call
            "file_key": file_key,
            "file_name": file_name,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "ts_unix_ms": int(time.time() * 1000),
        })
        return web.json_response({
            "code": 0, "msg": "", "data": {"file_key": file_key},
        })

    async def _on_get_sent_files(self, _request: web.Request) -> web.Response:
        linked = [f for f in self._uploaded_files if f["chat_id"]]
        return web.json_response(linked)

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
