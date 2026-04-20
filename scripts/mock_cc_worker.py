"""Mock CC worker for final_gate.sh --mock L1/L2/L6 checks.

Connects to esrd's channel WS (cli:channel/<session_id>), registers,
retries "session <sid> ready" until the feishu_thread peer is up,
and handles ECHO-PROBE notifications.

Uses aiohttp (already a project dep) over the Phoenix Channels v2 wire.

Usage:
    uv run --project py python scripts/mock_cc_worker.py \
        --session <session_id> [--chat-id <chat_id>] [--app-id <app_id>]
"""
from __future__ import annotations

import argparse
import asyncio
import itertools
import json
import logging
import os
import re
import sys
from pathlib import Path

import aiohttp

logger = logging.getLogger("mock_cc_worker")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)

WS_URL = "ws://127.0.0.1:4001/channel/socket/websocket?vsn=2.0.0"
ECHO_RE = re.compile(r"ECHO-PROBE:\s*(.+)")
READY_REPLY_TIMEOUT = 30.0  # seconds to keep retrying the ready reply


class MockCCWorker:
    def __init__(self, session_id: str, chat_id: str, app_id: str) -> None:
        self._session_id = session_id
        self._chat_id = chat_id
        self._app_id = app_id
        self._ref = itertools.count(1)
        self._topic = f"cli:channel/{session_id}"
        self._log_path = Path(f"/tmp/mock_cc_{session_id}.log")
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._join_ref: str = ""
        self._ready_sent = False

    def _next_ref(self) -> str:
        return str(next(self._ref))

    async def _send_str(self, s: str) -> None:
        assert self._ws is not None
        await self._ws.send_str(s)

    async def _send_envelope(self, payload: dict) -> str:
        """Send an envelope frame and return the ref used."""
        ref = self._next_ref()
        frame = json.dumps([self._join_ref, ref, self._topic, "envelope", payload])
        await self._send_str(frame)
        return ref

    async def run(self) -> None:
        # Truncate/create the per-session log file.
        self._log_path.write_text("")

        async with aiohttp.ClientSession() as http_session:
            async with http_session.ws_connect(WS_URL) as ws:
                self._ws = ws

                # 1. Join the channel
                join_ref = self._next_ref()
                self._join_ref = join_ref
                join_frame = json.dumps(
                    [join_ref, join_ref, self._topic, "phx_join", {}]
                )
                await self._send_str(join_frame)
                logger.info("sent phx_join for %s", self._topic)

                # Wait for join reply
                joined = False
                deadline = asyncio.get_event_loop().time() + 15
                while asyncio.get_event_loop().time() < deadline:
                    try:
                        msg = await asyncio.wait_for(ws.receive(), timeout=2.0)
                    except asyncio.TimeoutError:
                        continue
                    if msg.type != aiohttp.WSMsgType.TEXT:
                        if msg.type == aiohttp.WSMsgType.CLOSED:
                            logger.error("ws closed while waiting for join reply")
                            return
                        continue
                    frame = json.loads(msg.data)
                    if len(frame) < 5:
                        continue
                    _jref, _ref, topic, event, payload = frame
                    if event == "phx_reply" and topic == self._topic:
                        if (payload or {}).get("status") == "ok":
                            joined = True
                        else:
                            logger.error("join rejected: %s", payload)
                            return
                        break

                if not joined:
                    logger.error("never got join ok for %s", self._topic)
                    return

                logger.info("joined %s", self._topic)

                # 2. Register session
                await self._send_envelope({
                    "kind": "session_register",
                    "chats": [{"chat_id": self._chat_id, "app_id": self._app_id}],
                    "workspace": "esr-dev",
                })
                # Drain register reply (best-effort)
                try:
                    r = await asyncio.wait_for(ws.receive(), timeout=3.0)
                    _ = json.loads(r.data) if r.type == aiohttp.WSMsgType.TEXT else {}
                except asyncio.TimeoutError:
                    pass

                # 3. Start a background task that retries "session ready" until OK
                ready_task = asyncio.create_task(
                    self._send_ready_with_retry()
                )

                # 4. Main notification loop
                try:
                    while True:
                        try:
                            msg = await asyncio.wait_for(ws.receive(), timeout=25.0)
                        except asyncio.TimeoutError:
                            continue

                        if msg.type == aiohttp.WSMsgType.CLOSED:
                            logger.info("ws closed")
                            break
                        if msg.type != aiohttp.WSMsgType.TEXT:
                            continue

                        try:
                            frame = json.loads(msg.data)
                            if len(frame) < 5:
                                continue
                            _jref, ref, _topic, event, payload = frame
                        except (ValueError, json.JSONDecodeError):
                            continue

                        if event == "envelope":
                            kind = (payload or {}).get("kind", "")
                            if kind == "notification":
                                content = (payload or {}).get("content", "")
                                logger.info("notification: %r", content)
                                with self._log_path.open("a") as f:
                                    f.write(content + "\n")
                                m = ECHO_RE.search(content)
                                if m:
                                    nonce = m.group(1).strip()
                                    logger.info("ECHO-PROBE nonce=%r → _echo", nonce)
                                    await self._send_envelope({
                                        "kind": "tool_invoke",
                                        "req_id": self._next_ref(),
                                        "tool": "_echo",
                                        "args": {"nonce": nonce},
                                    })
                            elif kind == "session_killed":
                                logger.info("session_killed, shutting down")
                                break
                            elif kind == "tool_result":
                                req_id = (payload or {}).get("req_id")
                                ok = (payload or {}).get("ok", False)
                                logger.info("tool_result req_id=%s ok=%s", req_id, ok)
                                if ok and not self._ready_sent:
                                    # Successfully delivered the ready reply
                                    self._ready_sent = True
                                    logger.info("ready reply confirmed for %s", self._session_id)

                        elif event == "phx_reply":
                            # phx_reply for our envelope pushes
                            status = (payload or {}).get("status")
                            if status == "ok":
                                pass  # tool_invoke accepted
                            # Note: tool_result comes separately as an "envelope" event

                        elif event == "phx_error":
                            logger.error("phx_error: %s", payload)
                            break
                finally:
                    ready_task.cancel()
                    try:
                        await ready_task
                    except asyncio.CancelledError:
                        pass

    async def _send_ready_with_retry(self) -> None:
        """Retry sending 'session ready' tool_invoke until peer exists (max 30s)."""
        deadline = asyncio.get_event_loop().time() + READY_REPLY_TIMEOUT
        attempt = 0
        while asyncio.get_event_loop().time() < deadline and not self._ready_sent:
            if attempt > 0:
                await asyncio.sleep(2.0)
            attempt += 1
            try:
                await self._send_envelope({
                    "kind": "tool_invoke",
                    "req_id": self._next_ref(),
                    "tool": "reply",
                    "args": {
                        "chat_id": self._chat_id,
                        "text": f"session {self._session_id} ready",
                    },
                })
                logger.info("sent ready attempt #%d for session %s", attempt, self._session_id)
            except Exception as exc:
                logger.warning("send_ready attempt #%d error: %s", attempt, exc)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True)
    parser.add_argument(
        "--chat-id",
        default=os.environ.get("FEISHU_TEST_CHAT_ID", "oc_m1"),
    )
    parser.add_argument(
        "--app-id",
        default=os.environ.get("FEISHU_APP_ID", "cli_mock"),
    )
    args = parser.parse_args()

    worker = MockCCWorker(args.session, args.chat_id, args.app_id)

    async def _run() -> None:
        try:
            await worker.run()
        except Exception as exc:
            logger.error("worker error: %s", exc, exc_info=True)

    try:
        asyncio.run(_run())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
