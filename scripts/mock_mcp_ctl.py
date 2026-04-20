"""mock_mcp_ctl.py — scenario helper: one-shot tool_invoke over ChannelChannel.

Usage:
    mock_mcp_ctl.py --session <sid> --invoke <tool> --args '<json>'
"""
from __future__ import annotations

import argparse
import asyncio
import json
import secrets
import sys

import aiohttp


PHX_URL_DEFAULT = "ws://127.0.0.1:4001/channel/socket/websocket?vsn=2.0.0"


async def _run(session: str, invoke: str, args_json: str, url: str, timeout_s: float) -> int:
    args = json.loads(args_json)
    req_id = "ctl-" + secrets.token_hex(4)
    topic = f"cli:channel/{session}"
    join_ref = "1"
    msg_ref = "2"

    async with aiohttp.ClientSession() as sess:
        async with sess.ws_connect(url) as ws:
            await ws.send_json([join_ref, join_ref, topic, "phx_join", {}])

            join_reply = await asyncio.wait_for(ws.receive(), timeout_s)
            if join_reply.type != aiohttp.WSMsgType.TEXT:
                print(f"unexpected WS frame: {join_reply!r}", file=sys.stderr)
                return 2

            payload = json.loads(join_reply.data)
            # Phoenix v2 reply shape: [join_ref, ref, topic, "phx_reply", {"status":"ok","response":{}}]
            if not (isinstance(payload, list) and len(payload) == 5):
                print(f"unexpected join reply: {payload!r}", file=sys.stderr)
                return 2
            if payload[3] != "phx_reply" or payload[4].get("status") != "ok":
                print(f"join failed: {payload!r}", file=sys.stderr)
                return 2

            envelope = {
                "kind": "tool_invoke",
                "req_id": req_id,
                "tool": invoke,
                "args": args,
            }
            await ws.send_json([join_ref, msg_ref, topic, "envelope", envelope])

            # Await a tool_result envelope for our req_id.
            deadline = asyncio.get_event_loop().time() + timeout_s

            while asyncio.get_event_loop().time() < deadline:
                remaining = deadline - asyncio.get_event_loop().time()
                try:
                    msg = await asyncio.wait_for(ws.receive(), remaining)
                except asyncio.TimeoutError:
                    break

                if msg.type != aiohttp.WSMsgType.TEXT:
                    continue

                frame = json.loads(msg.data)
                if not (isinstance(frame, list) and len(frame) == 5):
                    continue

                if frame[3] == "envelope" and isinstance(frame[4], dict):
                    env = frame[4]
                    if env.get("kind") == "tool_result" and env.get("req_id") == req_id:
                        print(json.dumps(env, ensure_ascii=False))
                        return 0 if env.get("ok") else 1

    print(f"timeout waiting for tool_result req_id={req_id}", file=sys.stderr)
    return 2


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--session", required=True)
    p.add_argument("--invoke", required=True)
    p.add_argument("--args", required=True, help="JSON string")
    p.add_argument("--url", default=PHX_URL_DEFAULT)
    p.add_argument("--timeout", type=float, default=10.0)
    ns = p.parse_args()

    return asyncio.run(_run(ns.session, ns.invoke, ns.args, ns.url, ns.timeout))


if __name__ == "__main__":
    sys.exit(main())
