"""WebSocket client to esrd — reconnect with jitter (spec §6.2b).

This layer knows about esrd URL + session identity but NOT about
MCP tool protocol. It exposes:

- connect_and_run(on_envelope) — run forever; call on_envelope(dict)
  for each inbound 'envelope' frame; terminate only when the enclosing
  task group cancels (CC stdio EOF).
- push(envelope) — send an envelope frame.
"""
from __future__ import annotations

import asyncio
import json
import logging
import random
from collections.abc import Awaitable, Callable
from typing import Any

import aiohttp

logger = logging.getLogger(__name__)


def compute_backoff(attempt: int, *, rng: Callable[[], float] = random.random) -> float:
    """Jittered exponential backoff (spec §6.2b).

    delay = min(30, 2^attempt) * (0.5 + rng())

    - `attempt` starts at 0 for the first retry.
    - `rng` must return a float in [0, 1); override in tests for determinism.
    """
    base = min(30.0, float(2 ** attempt))
    factor = 0.5 + rng()
    return base * factor


class EsrWSClient:
    def __init__(self, *, url: str, session_id: str, workspace: str,
                 chats: list[dict[str, Any]]) -> None:
        self._url = url
        self._session_id = session_id
        self._workspace = workspace
        self._chats = chats
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._ref = 0
        self._join_ref = "cli-channel-join"
        self._attempt = 0
        self._topic = f"cli:channel/{session_id}"

    def _next_ref(self) -> str:
        self._ref += 1
        return str(self._ref)

    async def _send_frame(self, event: str, payload: dict[str, Any]) -> None:
        if self._ws is None:
            raise RuntimeError("ws not connected")
        # Phoenix v2 array frame: [join_ref, ref, topic, event, payload]
        frame = [self._join_ref, self._next_ref(), self._topic, event, payload]
        await self._ws.send_str(json.dumps(frame))

    async def push(self, envelope: dict[str, Any]) -> None:
        """Queue-free send — raises if WS is not currently connected."""
        await self._send_frame("envelope", envelope)

    async def connect_and_run(
        self, on_envelope: Callable[[dict[str, Any]], Awaitable[None]]
    ) -> None:
        """Reconnect loop until task group cancels."""
        async with aiohttp.ClientSession() as session:
            while True:
                try:
                    await self._session_loop(session, on_envelope)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:  # noqa: BLE001 — wide by design
                    logger.info("ws session error: %s; backing off", exc)

                self._attempt += 1
                delay = compute_backoff(self._attempt)
                logger.info("reconnect in %.2fs (attempt %d)", delay, self._attempt)
                await asyncio.sleep(delay)

    async def _session_loop(
        self,
        session: aiohttp.ClientSession,
        on_envelope: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        url = self._url.rstrip("/") + "/channel/socket/websocket?vsn=2.0.0"
        async with session.ws_connect(url, heartbeat=30) as ws:
            self._ws = ws
            self._attempt = 0

            # Phoenix v2 join: ["<jref>","<ref>", topic, "phx_join", {}]
            await ws.send_str(json.dumps(
                [self._join_ref, self._next_ref(), self._topic, "phx_join", {}]))

            # On join, push session_register so esrd has chat_ids.
            await self.push({
                "kind": "session_register",
                "session_id": self._session_id,
                "workspace": self._workspace,
                "chats": self._chats,
            })

            async for msg in ws:
                if msg.type != aiohttp.WSMsgType.TEXT:
                    continue
                try:
                    frame = json.loads(msg.data)
                except (ValueError, TypeError):
                    continue
                if len(frame) < 5:
                    continue
                event, payload = frame[3], frame[4]
                if event != "envelope" or not isinstance(payload, dict):
                    continue
                await on_envelope(payload)

            self._ws = None
