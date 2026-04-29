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
        # PR-A T6: data model partitioned by app_id. Existing scenarios that
        # don't carry `app_id` (no `?app_id=` query on /ws, no `X-App-Id`
        # header on POST) land in the "default" bucket — back-compat for
        # scenarios 01-03.
        self._sent_messages: dict[str, list[dict[str, Any]]] = {}
        # per-chat history — newest-first order for each list
        self._chat_history: dict[str, list[dict[str, Any]]] = {}
        self._runner: web.AppRunner | None = None
        self._site: web.TCPSite | None = None
        self._port: int | None = None
        # connected WS clients keyed by app_id — adapter opens one per app
        self._ws_clients: dict[str, list[web.WebSocketResponse]] = {}
        # reactions + uploaded files (T0 §4)
        self._reactions: dict[str, list[dict[str, Any]]] = {}
        # PR-9 T5c: un-reactions, recorded so tests can assert that
        # FeishuChatProxy un-reacted a specific message_id when CC's
        # reply carried `reply_to_message_id`.
        self._un_reactions: dict[str, list[dict[str, Any]]] = {}
        # PR-A T7 seam: chat membership per app — set populated via
        # register_chat_membership(); enforced in _on_create_message
        # only when X-App-Id != "default" (back-compat).
        self._chat_membership: dict[str, set[str]] = {}
        self._uploaded_files: list[dict[str, Any]] = []
        self._files_dir: Path | None = None  # set in start()

    # -- public API -----------------------------------------------------

    @property
    def sent_messages(self) -> list[dict[str, Any]]:
        # Return the union across all per-app buckets — preserves the
        # pre-T6 contract for any in-process callers that read this
        # property (tests etc.). Per-app reads use the GET endpoint.
        union: list[dict[str, Any]] = []
        for msgs in self._sent_messages.values():
            union.extend(msgs)
        return union

    def register_chat_membership(self, app_id: str, chat_id: str) -> None:
        """Mark `app_id`'s bot as a member of `chat_id`. T7 uses this to
        reject outbound from non-member apps."""
        self._chat_membership.setdefault(app_id, set()).add(chat_id)

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
        # PR-A T8 anticipation: scenarios pre-register chat membership
        # so T7's outbound rejection only fires when intended (i.e.
        # cross-app non-member case). Without this, every outbound from
        # an adapter that sets X-App-Id != "default" gets rejected
        # because membership is empty.
        app.router.add_post(
            "/register_membership", self._on_register_membership
        )

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
        for clients in self._ws_clients.values():
            for ws in clients:
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
        app_id: str = "default",
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

        T6 partitions routing on `app_id`: only WS clients that subscribed
        with matching `?app_id=<value>` receive the envelope. Clients
        that didn't pass the query land in the "default" bucket.
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
        for ws in list(self._ws_clients.get(app_id, [])):
            if not ws.closed:
                # Schedule the send without awaiting — callers use this
                # from sync test code.
                asyncio.create_task(ws.send_str(data))  # noqa: RUF006
        return msg_id

    # -- handlers -------------------------------------------------------

    async def _on_create_message(self, request: web.Request) -> web.Response:
        """POST /open-apis/im/v1/messages — bot sends a message to a chat.

        PR-A T6: caller identifies its app via the `X-App-Id` header.
        Default ("default") preserves pre-T6 behaviour for scenarios
        01-03 that don't set the header.
        """
        body = await request.json()
        message_id = _new_message_id()
        app_id = request.headers.get("X-App-Id", "default")
        receive_id = body.get("receive_id")

        # PR-A T7: real-Feishu parity — reject when calling app isn't
        # a member of the target chat. The "default" bucket bypasses
        # this check for back-compat with scenarios 01-03 that don't
        # set X-App-Id.
        if app_id != "default":
            members = self._chat_membership.get(app_id, set())
            if receive_id not in members:
                return web.json_response({
                    "code": 230002,
                    "msg": (
                        f"app {app_id!r} is not a member of "
                        f"chat {receive_id!r}"
                    ),
                    "data": {},
                })

        record = {
            "message_id": message_id,
            "receive_id_type": request.query.get("receive_id_type", "chat_id"),
            "receive_id": body.get("receive_id"),
            "msg_type": body.get("msg_type"),
            "content": body.get("content"),
            "ts_unix_ms": int(time.time() * 1000),
            "app_id": app_id,
        }
        self._sent_messages.setdefault(app_id, []).append(record)

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
        """GET /ws upgrade — adapter subscribes here for inbound events.

        PR-A T6: clients select the per-app routing bucket via the
        `?app_id=<id>` query. Clients that omit it land in "default" —
        same-shape behaviour as pre-T6 for scenarios 01-03.
        """
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        app_id = request.query.get("app_id", "default")
        self._ws_clients.setdefault(app_id, []).append(ws)
        try:
            async for _msg in ws:  # keep the connection open; discard inbound
                pass
        finally:
            bucket = self._ws_clients.get(app_id)
            if bucket is not None and ws in bucket:
                bucket.remove(ws)
        return ws

    async def _on_get_ws_clients(self, _request: web.Request) -> web.Response:
        """GET /ws_clients — return the count of connected /ws subscribers.

        Readiness probe for the PR-9 T9 sidecar-ready check: the feishu
        adapter subprocess only opens its ws_connect to /ws after
        Phoenix join + handler_hello succeed, so a non-zero count
        signals the full start-up chain is up and push_inbound will be
        delivered.

        PR-A T6: returns the union count across all per-app buckets so
        wait_for_sidecar_ready (which doesn't know about app_ids)
        keeps working unchanged.
        """
        total = sum(len(clients) for clients in self._ws_clients.values())
        return web.json_response({"count": total})

    async def _on_push_inbound(self, request: web.Request) -> web.Response:
        """POST /push_inbound — scenario helper: inject a Feishu-side
        inbound message as if a user typed it. Body JSON shape:
        {"chat_id": "oc_x", "app_id": "cli_x", "user": "ou_user1",
         "text": "/new-session esr-dev name=root cwd=/path/to/wt worktree=root"}

        PR-A T6: optional `app_id` selects the routing bucket. When
        omitted, the helper fans out to **every currently-connected
        app bucket** — preserves the pre-T6 implicit "deliver to whoever
        is listening" semantic that scenarios 01-03 rely on. Once the
        adapter sends `?app_id=<actor_id>` on its WS connect (PR-A T6
        follow-up), the only-listener bucket is the adapter's app id,
        so fanout still goes to exactly one place. Multi-app scenarios
        (04+) MUST pass `app_id` explicitly to avoid cross-app spillover.
        """
        body = await request.json()
        chat_id = body.get("chat_id", "")
        sender_open_id = body.get("user", "ou_test")
        content_text = body.get("text", "")

        explicit_app_id = body.get("app_id")
        if explicit_app_id:
            msg_id = self.push_inbound(
                chat_id=chat_id,
                sender_open_id=sender_open_id,
                content_text=content_text,
                app_id=explicit_app_id,
            )
            return web.json_response({"ok": True, "message_id": msg_id})

        # Fanout: drop into every bucket that has at least one client.
        # This is back-compat for one-adapter scenarios (only one bucket
        # exists) and matches the pre-T6 "broadcast to all" behaviour.
        # Returns the message_id of the first delivery (all deliveries
        # share the same synthesised id is intentional — same envelope).
        connected_buckets = [
            app_id
            for app_id, clients in self._ws_clients.items()
            if any(not ws.closed for ws in clients)
        ]
        if not connected_buckets:
            # No clients yet — degrade gracefully like the pre-T6 path
            # (push to "default" so the message is still recorded for
            # late-arrival diagnostics, even though nothing receives).
            connected_buckets = ["default"]

        msg_id = ""
        for app_id in connected_buckets:
            msg_id = self.push_inbound(
                chat_id=chat_id,
                sender_open_id=sender_open_id,
                content_text=content_text,
                app_id=app_id,
            )

        return web.json_response({"ok": True, "message_id": msg_id})

    async def _on_register_membership(self, request: web.Request) -> web.Response:
        """POST /register_membership — scenario helper: mark `app_id`'s
        bot as a member of `chat_id`. T7 uses the membership map to
        reject outbound from non-member apps. Body JSON shape:
        {"app_id": "feishu_app_dev", "chat_id": "oc_pra_dev"}
        """
        body = await request.json()
        app_id = body.get("app_id", "default")
        chat_id = body.get("chat_id", "")
        self.register_chat_membership(app_id, chat_id)
        return web.json_response({"ok": True})

    async def _on_get_sent_messages(self, request: web.Request) -> web.Response:
        """GET /sent_messages — scenario helper: return the outbound
        message log as a JSON array for grep-style assertions.

        PR-A T6: optional `?app_id=` scopes to one app's bucket; absent
        returns the union across all buckets (back-compat).
        """
        app_id = request.query.get("app_id")
        if app_id is not None:
            return web.json_response(list(self._sent_messages.get(app_id, [])))
        union: list[dict[str, Any]] = []
        for msgs in self._sent_messages.values():
            union.extend(msgs)
        return web.json_response(union)

    async def _on_create_reaction(self, request: web.Request) -> web.Response:
        message_id = request.match_info["message_id"]
        body = await request.json()
        emoji_type = body.get("reaction_type", {}).get("emoji_type", "")
        reaction_id = "rc_mock_" + secrets.token_hex(8)
        app_id = request.headers.get("X-App-Id", "default")
        self._reactions.setdefault(app_id, []).append({
            "message_id": message_id,
            "emoji_type": emoji_type,
            "ts_unix_ms": int(time.time() * 1000),
            "app_id": app_id,
        })
        return web.json_response({
            "code": 0,
            "msg": "",
            "data": {"reaction_id": reaction_id, "message_id": message_id},
        })

    async def _on_get_reactions(self, request: web.Request) -> web.Response:
        """PR-A T6: optional `?app_id=` scopes to one bucket; absent → union."""
        app_id = request.query.get("app_id")
        if app_id is not None:
            return web.json_response(list(self._reactions.get(app_id, [])))
        union: list[dict[str, Any]] = []
        for entries in self._reactions.values():
            union.extend(entries)
        return web.json_response(union)

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
        app_id = request.headers.get("X-App-Id", "default")
        self._un_reactions.setdefault(app_id, []).append({
            "message_id": message_id,
            "reaction_id": reaction_id,
            "ts_unix_ms": int(time.time() * 1000),
            "app_id": app_id,
        })
        # Remove the first matching reaction (by message_id) within
        # this app's bucket, if any.
        bucket = self._reactions.get(app_id, [])
        for idx, entry in enumerate(bucket):
            if entry["message_id"] == message_id:
                bucket.pop(idx)
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
        app_id = request.headers.get("X-App-Id", "default")

        bucket = self._reactions.get(app_id, [])
        removed = [r for r in bucket if r["message_id"] == message_id]
        self._reactions[app_id] = [
            r for r in bucket if r["message_id"] != message_id
        ]
        un_bucket = self._un_reactions.setdefault(app_id, [])
        for r in removed:
            un_bucket.append({
                "message_id": message_id,
                "emoji_type": emoji_type or r.get("emoji_type", ""),
                "ts_unix_ms": int(time.time() * 1000),
                "app_id": app_id,
            })
        if not removed:
            # Still record the un-react attempt so tests can assert the
            # directive fired even when no live reaction existed (e.g.
            # race where the inbound react hadn't completed yet).
            un_bucket.append({
                "message_id": message_id,
                "emoji_type": emoji_type,
                "ts_unix_ms": int(time.time() * 1000),
                "app_id": app_id,
            })
        return web.json_response({"code": 0, "msg": "", "data": {}})

    async def _on_get_un_reactions(self, request: web.Request) -> web.Response:
        """GET /un_reactions — scenario helper: return the un-react log.

        PR-A T6: optional `?app_id=` scopes to one bucket; absent → union.
        """
        app_id = request.query.get("app_id")
        if app_id is not None:
            return web.json_response(list(self._un_reactions.get(app_id, [])))
        union: list[dict[str, Any]] = []
        for entries in self._un_reactions.values():
            union.extend(entries)
        return web.json_response(union)

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
