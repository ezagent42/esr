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
import os
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from esr.adapter import AdapterConfig, adapter
from esr.capabilities import CapabilitiesChecker
from esr.workspaces import read_workspaces

logger = logging.getLogger(__name__)

_BACKOFF_SCHEDULE: tuple[float, ...] = (1.0, 2.0, 4.0, 8.0, 16.0, 30.0)
"""Exponential backoff between 429 retries (PRD 04 F15). Total budget 30s."""

_RETRY_DEADLINE_S: float = 30.0
"""Wall-clock ceiling for all combined retry delays (spec §7.3)."""

_DENY_WINDOW_S: float = 600.0
"""Minimum seconds between deny DMs to the same principal (Lane A, spec §7.1).

Prevents an unauthorized user from being spammed if they send many
messages — one warning per 10-minute window, further messages dropped
silently."""

_DENY_DM_TEXT: str = "你无权使用此 bot，请联系管理员授权。"
"""Plain-text reply sent once per ``_DENY_WINDOW_S`` to a denied principal."""


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
        "urllib": ["127.0.0.1", "localhost"],
        "base64": "*",
        "hashlib": "*",
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
        # Capabilities spec §6.2/§6.3: every msg_received envelope
        # carries `principal_id` (sender.open_id) and `workspace_name`
        # (reverse-lookup from the (chat_id, app_id) tuple against
        # workspaces.yaml). Load the reverse-lookup map at startup;
        # missing file → empty map → every envelope emits
        # `workspace_name=None` and Lane A / Lane B treat that as the
        # "chat not bound to any workspace" case.
        self._workspace_of: dict[tuple[str, str], str] = (
            self._load_workspace_map()
        )
        # Lane A (spec §7.1): adapter enforces msg.send before emitting
        # msg_received into the runtime. Unauthorized principals get one
        # rate-limited deny DM per 10 min; their messages are dropped.
        # CapabilitiesChecker reloads lazily by mtime, so an admin
        # editing capabilities.yaml is picked up within one message.
        self._caps: CapabilitiesChecker = self._load_capabilities_checker()
        # {open_id → last deny DM monotonic ts}. Mutated only inside
        # the asyncio loop (the async emit paths enter directly; the
        # sync WS callback dispatches via run_coroutine_threadsafe), so
        # no lock is needed — the coroutine runs serially on the loop.
        self._last_deny_ts: dict[str, float] = {}

    @property
    def app_id(self) -> str:
        """The Feishu app_id this adapter is bound to (one-liner for
        call sites that need it for the (chat_id, app_id) lookup)."""
        return self._config.app_id

    def _load_workspace_map(self) -> dict[tuple[str, str], str]:
        """Build the ``(chat_id, app_id) → workspace_name`` dict from
        the workspaces.yaml at ``${ESRD_HOME:-~/.esrd}/default/workspaces.yaml``.

        Config override: if ``AdapterConfig`` carries a
        ``workspaces_path`` key (used by tests), prefer that. Missing
        file returns an empty dict — callers get
        ``workspace_name=None`` on every envelope, which Lane A treats
        as "deny unless bootstrap".
        """
        configured = (
            getattr(self._config, "workspaces_path", None)
            if hasattr(self._config, "workspaces_path")
            else None
        )
        if configured:
            path = Path(configured)
        else:
            esrd_home = os.environ.get("ESRD_HOME") or str(
                Path.home() / ".esrd"
            )
            path = Path(esrd_home) / "default" / "workspaces.yaml"

        try:
            workspaces = read_workspaces(path)
        except Exception as exc:  # noqa: BLE001 — startup boundary
            logger.warning(
                "feishu adapter: workspaces.yaml load failed (%s); "
                "envelopes will carry workspace_name=None",
                exc,
            )
            return {}

        out: dict[tuple[str, str], str] = {}
        for ws in workspaces.values():
            for chat in ws.chats:
                chat_id = chat.get("chat_id")
                app_id = chat.get("app_id")
                if isinstance(chat_id, str) and isinstance(app_id, str):
                    out[(chat_id, app_id)] = ws.name
        return out

    def _load_capabilities_checker(self) -> CapabilitiesChecker:
        """Construct a ``CapabilitiesChecker`` bound to
        ``${ESRD_HOME:-~/.esrd}/default/capabilities.yaml``.

        Config override: ``AdapterConfig.capabilities_path`` (used by
        tests). Missing file is fine — the checker treats it as an
        empty snapshot, i.e. default-deny for everyone. The checker
        itself is mtime-gated so later edits are picked up without a
        restart.
        """
        configured = (
            getattr(self._config, "capabilities_path", None)
            if hasattr(self._config, "capabilities_path")
            else None
        )
        if configured:
            path = Path(configured)
        else:
            esrd_home = os.environ.get("ESRD_HOME") or str(
                Path.home() / ".esrd"
            )
            path = Path(esrd_home) / "default" / "capabilities.yaml"
        return CapabilitiesChecker(path)

    # --- Lane A gate (spec §7.1) -------------------------------------

    def _is_authorized(self, open_id: str, chat_id: str) -> bool:
        """True if ``open_id`` may send a ``msg_received`` for ``chat_id``.

        Checks the CapabilitiesChecker for ``workspace:<name>/msg.send``.
        Unbound chats (no workspace in workspaces.yaml) are denied —
        a chat not attached to a workspace cannot be authorized against
        a workspace-scoped permission.
        """
        if not open_id:
            return False
        workspace = self._workspace_of.get((chat_id, self.app_id))
        if workspace is None:
            return False
        return self._caps.has(
            principal_id=open_id,
            permission=f"workspace:{workspace}/msg.send",
        )

    def _should_send_deny(self, open_id: str) -> bool:
        """Rate-limit bookkeeping: True iff we should send a deny DM now.

        Called only from inside ``_deny_rate_limited`` which runs on
        the asyncio loop — no cross-thread synchronization needed
        because the three inbound paths all converge through that
        coroutine (the sync WS callback dispatches via
        ``run_coroutine_threadsafe``).

        When True, records ``time.monotonic()`` as the new last-send ts
        so the next message within ``_DENY_WINDOW_S`` stays silent.
        """
        now = time.monotonic()
        last = self._last_deny_ts.get(open_id, 0.0)
        if now - last < _DENY_WINDOW_S:
            return False
        self._last_deny_ts[open_id] = now
        return True

    async def _deny_rate_limited(self, open_id: str, chat_id: str) -> None:
        """Send the deny DM to ``chat_id`` if the rate-limit window
        permits. Async so the async emit paths can ``await`` it.

        Best-effort: failures (no network, lark 5xx, etc.) are logged
        but never raised — a bad deny DM shouldn't crash the adapter
        loop. The actual send reuses ``_send_message`` so the mock and
        live paths stay symmetric; since that helper is sync (urllib
        for the mock, lark_oapi for live), we dispatch it to the
        default executor so an in-process mock (aiohttp on the same
        loop) can actually answer.
        """
        if not self._should_send_deny(open_id):
            return
        try:
            loop = asyncio.get_running_loop()
            result = await loop.run_in_executor(
                None,
                self._send_message,
                {"chat_id": chat_id, "content": _DENY_DM_TEXT},
            )
            if not result.get("ok"):
                logger.debug(
                    "feishu Lane A: deny DM to %s on %s failed: %s",
                    open_id,
                    chat_id,
                    result.get("error", ""),
                )
        except Exception as exc:  # noqa: BLE001 — best-effort boundary
            logger.debug(
                "feishu Lane A: deny DM raised (non-fatal): %s", exc
            )

    def _build_msg_received_envelope(
        self,
        args: dict[str, Any],
        sender_open_id: str,
    ) -> dict[str, Any]:
        """Construct the canonical ``msg_received`` envelope dict.

        Factored helper called from all three inbound paths (WS live,
        polling fallback, mock). Sets ``principal_id`` to the sender's
        open_id and ``workspace_name`` from the reverse-lookup map
        (None if the (chat_id, app_id) tuple isn't bound to any
        workspace).
        """
        chat_id = args.get("chat_id") or ""
        return {
            "event_type": "msg_received",
            "args": args,
            "principal_id": sender_open_id or None,
            "workspace_name": self._workspace_of.get(
                (chat_id, self.app_id)
            ),
        }

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
            base_url = getattr(self._config, "base_url", "") or ""
            if base_url.startswith(("http://127.0.0.1", "http://localhost")):
                loop = asyncio.get_running_loop()
                return await loop.run_in_executor(None, self._react, args)
            return await self._with_ratelimit_retry(lambda: self._react(args))
        if action == "un_react":
            # PR-9 T5c: un-react by message_id (v1 best-effort — no
            # reaction_id tracking on the Elixir side). Mock path POSTs
            # to the DELETE-by-message_id endpoint; live path uses
            # lark_oapi's reaction.delete.
            base_url = getattr(self._config, "base_url", "") or ""
            if base_url.startswith(("http://127.0.0.1", "http://localhost")):
                loop = asyncio.get_running_loop()
                return await loop.run_in_executor(None, self._un_react, args)
            return await self._with_ratelimit_retry(lambda: self._un_react(args))
        if action == "send_card":
            return await self._with_ratelimit_retry(lambda: self._send_card(args))
        if action == "pin":
            return await self._with_ratelimit_retry(lambda: self._pin(args))
        if action == "unpin":
            return await self._with_ratelimit_retry(lambda: self._unpin(args))
        if action == "download_file":
            return self._download_file(args)
        if action == "send_file":
            # send_file's mock path does sync HTTP; dispatch through the
            # executor so an in-process aiohttp mock on the same loop can
            # answer. Parity with _deny_rate_limited.
            loop = asyncio.get_running_loop()
            return await loop.run_in_executor(None, self._send_file, args)
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
        """Send a text message. Mock path: POST to mock_feishu when
        base_url points at 127.0.0.1/localhost. Live path: lark_oapi
        im.v1.message.create (PRD 04 F07)."""
        chat_id = args["chat_id"]
        content = args["content"]

        base_url = getattr(self._config, "base_url", None) if (
            hasattr(self._config, "base_url")
        ) else None
        if isinstance(base_url, str) and (
            base_url.startswith("http://127.0.0.1")
            or base_url.startswith("http://localhost")
        ):
            return self._send_message_mock(base_url, chat_id, content)

        import lark_oapi.api.im.v1 as im_v1

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

    def _send_message_mock(self, base_url: str, chat_id: str, content: str) -> dict[str, Any]:
        import urllib.request
        import urllib.error

        body = json.dumps({
            "receive_id": chat_id,
            "msg_type": "text",
            "content": json.dumps({"text": content}),
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
            data=body,
            headers={"content-type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                return {"ok": True, "result": data.get("data") or {}}
        except urllib.error.URLError as exc:
            return {"ok": False, "error": f"mock POST failed: {exc}"}

    def _react(self, args: dict[str, Any]) -> dict[str, Any]:
        """Create a reaction on a message. Mock path: POST to mock_feishu
        when base_url is 127.0.0.1/localhost. Live path: lark_oapi (PRD 04 F08)."""
        msg_id = args["msg_id"]
        emoji_type = args["emoji_type"]

        base_url = getattr(self._config, "base_url", "") or ""
        if base_url.startswith(("http://127.0.0.1", "http://localhost")):
            return self._react_mock(base_url, msg_id, emoji_type)

        import lark_oapi.api.im.v1 as im_v1
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

    def _react_mock(
        self, base_url: str, msg_id: str, emoji_type: str
    ) -> dict[str, Any]:
        import urllib.error
        import urllib.request

        body = json.dumps({
            "reaction_type": {"emoji_type": emoji_type},
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{base_url}/open-apis/im/v1/messages/{msg_id}/reactions",
            data=body,
            headers={"content-type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                return {"ok": True, "result": data.get("data") or {}}
        except urllib.error.URLError as exc:
            return {"ok": False, "error": f"mock react failed: {exc}"}

    def _un_react(self, args: dict[str, Any]) -> dict[str, Any]:
        """Remove a reaction from a message. PR-9 T5c.

        v1 shape: delete by ``msg_id`` alone (no reaction_id). Mock path
        calls the DELETE-by-message_id endpoint; live path enumerates
        reactions on the message and deletes the first matching one —
        kept as a stub until the live path is exercised (parity with
        ``_send_file_live``).
        """
        msg_id = args["msg_id"]
        emoji_type = args.get("emoji_type", "")

        base_url = getattr(self._config, "base_url", "") or ""
        if base_url.startswith(("http://127.0.0.1", "http://localhost")):
            return self._un_react_mock(base_url, msg_id, emoji_type)

        import lark_oapi.api.im.v1 as im_v1  # noqa: F401 — import guard
        # Live path deferred: Lark's DELETE reaction API requires a
        # reaction_id; FeishuChatProxy's v1 tracking carries only the
        # message_id + emoji_type. Implementing this live path means
        # enumerating reactions on the message first. Safe no-op here —
        # the production un-react path against the real Lark API is a
        # follow-up (the delivery-ack react itself is cosmetic).
        return {"ok": False, "error": "live un_react not yet implemented"}

    def _un_react_mock(
        self, base_url: str, msg_id: str, emoji_type: str
    ) -> dict[str, Any]:
        import urllib.error
        import urllib.request

        body = json.dumps({
            "reaction_type": {"emoji_type": emoji_type},
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{base_url}/open-apis/im/v1/messages/{msg_id}/reactions",
            data=body,
            headers={"content-type": "application/json"},
            method="DELETE",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                return {"ok": True, "result": data.get("data") or {}}
        except urllib.error.URLError as exc:
            return {"ok": False, "error": f"mock un_react failed: {exc}"}

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

    def _send_file(self, args: dict[str, Any]) -> dict[str, Any]:
        """α wire shape (spec §6.1): base64 in-band + sha256 check."""
        import base64 as _b64
        import hashlib

        chat_id = args["chat_id"]
        file_name = args["file_name"]
        content_b64 = args["content_b64"]
        expected_sha = args["sha256"]

        try:
            bytes_ = _b64.b64decode(content_b64, validate=True)
        except Exception as exc:  # noqa: BLE001 — surface any b64 error
            return {"ok": False, "error": f"b64 decode failed: {exc}"}

        actual_sha = hashlib.sha256(bytes_).hexdigest()
        if actual_sha != expected_sha:
            return {"ok": False, "error": "sha256 mismatch"}

        base_url = getattr(self._config, "base_url", "") or ""
        if base_url.startswith(("http://127.0.0.1", "http://localhost")):
            return self._send_file_mock(base_url, chat_id, file_name, bytes_)

        return self._send_file_live(chat_id, file_name, bytes_)

    def _send_file_mock(
        self, base_url: str, chat_id: str, file_name: str, bytes_: bytes
    ) -> dict[str, Any]:
        import base64 as _b64
        import urllib.error
        import urllib.request

        upload_body = json.dumps({
            "file_type": "stream",
            "file_name": file_name,
            "content_b64": _b64.b64encode(bytes_).decode(),
        }).encode("utf-8")
        upload_req = urllib.request.Request(
            f"{base_url}/open-apis/im/v1/files",
            data=upload_body,
            headers={"content-type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(upload_req, timeout=5) as resp:
                upload = json.loads(resp.read())
        except urllib.error.URLError as exc:
            return {"ok": False, "error": f"mock upload failed: {exc}"}

        file_key = upload.get("data", {}).get("file_key")
        if not file_key:
            return {"ok": False, "error": "mock upload did not return file_key"}

        msg_body = json.dumps({
            "receive_id": chat_id,
            "msg_type": "file",
            "content": json.dumps({"file_key": file_key}),
        }).encode("utf-8")
        msg_req = urllib.request.Request(
            f"{base_url}/open-apis/im/v1/messages?receive_id_type=chat_id",
            data=msg_body,
            headers={"content-type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(msg_req, timeout=5) as resp:
                data = json.loads(resp.read())
        except urllib.error.URLError as exc:
            return {"ok": False, "error": f"mock send-file-message failed: {exc}"}
        return {"ok": True, "result": data.get("data") or {"file_key": file_key}}

    def _send_file_live(
        self, chat_id: str, file_name: str, bytes_: bytes
    ) -> dict[str, Any]:
        """Live path parity with _send_message. Untested in PR-7 (mock-only)."""
        import lark_oapi.api.im.v1 as im_v1  # noqa: F401 — import guard
        # Deferred: two-step upload + message create against real Lark.
        return {"ok": False, "error": "live send_file not yet implemented"}

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
        """Live path — drive lark_oapi.ws.Client and a bot-self polling
        fallback, yielding received messages from whichever surfaces them.

        Lark's ``im.message.receive_v1`` event **does not fire** for
        messages the bot itself posts via the REST API. That's the
        blocker for final_gate.sh --live, which bot-posts the
        ``/new-thread SMOKE-XXX`` message then expects to see it flow
        through the adapter into the handler pipeline. To close this
        gap without changing the gate script, we augment the WS path
        with a cooperative polling task on ``poll_chat_id`` (config or
        env ``FEISHU_TEST_CHAT_ID``): every 2 s we call
        ``im.v1.message.list`` and synthesise ``msg_received`` events
        for fresh messages we have not seen. Real user-to-bot messages
        still flow through the WS path with sub-second latency; bot-
        self messages are delivered within the polling cadence.
        """
        import lark_oapi
        from lark_oapi.event.dispatcher_handler import EventDispatcherHandler

        # lark_oapi has its own logger (INFO-level by default) — bump to
        # DEBUG so frame-level activity lands in our adapter log for --live
        # diagnostics.
        try:
            from lark_oapi.core.log import logger as _lark_logger

            _lark_logger.setLevel(logging.DEBUG)
        except Exception:  # noqa: BLE001 — diagnostic only
            pass

        loop = asyncio.get_running_loop()
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()

        def _handle_receive(data: Any) -> None:
            # data is a P2ImMessageReceiveV1 pydantic-like object. Lark
            # nests the message under data.event.message; we flatten to
            # the minimum the feishu_app handler needs.
            logger.info("lark im.message.receive_v1 received (event keys=%s)",
                        list(getattr(data, "__dict__", {}).keys()) if data else "none")
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
                sender_open_id = getattr(
                    getattr(sender, "sender_id", None), "open_id", ""
                ) or ""
                chat_id = getattr(message, "chat_id", "") or ""
                # Lane A (spec §7.1): check msg.send before enqueueing.
                # This callback fires from a lark_oapi executor thread,
                # so an unauthorised denial schedules the deny DM on the
                # main loop via run_coroutine_threadsafe — the network
                # call must happen on an asyncio loop, not this thread.
                if not self._is_authorized(sender_open_id, chat_id):
                    asyncio.run_coroutine_threadsafe(
                        self._deny_rate_limited(sender_open_id, chat_id),
                        loop,
                    )
                    return
                payload = self._build_msg_received_envelope(
                    args={
                        "chat_id": chat_id,
                        # PR-A T1: app_id is the ESR instance_id (the
                        # adapters.yaml `instances:` key, e.g.
                        # `feishu_app_e2e-mock`), NOT the Feishu wire
                        # `cli_xxx`. The Elixir FeishuAppAdapter reads
                        # this to key SessionRegistry's 3-tuple so two
                        # apps with overlapping chat_ids never collide.
                        "app_id": self.actor_id,
                        "message_id": getattr(message, "message_id", "") or "",
                        "content": extracted,
                        "raw_content": raw_content,
                        "msg_type": msg_type,
                        "sender_id": sender_open_id,
                        "sender_type": getattr(sender, "sender_type", "") or "",
                        "thread_id": getattr(message, "thread_id", "") or "",
                        "root_id": getattr(message, "root_id", "") or "",
                    },
                    sender_open_id=sender_open_id,
                )
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

        # Start the polling fallback task if a chat id is configured or
        # visible via FEISHU_TEST_CHAT_ID (set by final_gate.sh --live).
        poll_chat_id = (
            getattr(self._config, "poll_chat_id", None)
            if hasattr(self._config, "poll_chat_id")
            else None
        )
        if not poll_chat_id:
            import os
            poll_chat_id = os.environ.get("FEISHU_TEST_CHAT_ID") or ""

        poll_task = (
            asyncio.create_task(self._poll_chat_messages(poll_chat_id, queue))
            if poll_chat_id
            else None
        )

        try:
            while True:
                event = await queue.get()
                yield event
        finally:
            # start() has no clean shutdown API in lark_oapi; cancelling
            # the executor future severs the wait, the daemon thread will
            # exit on process teardown.
            ws_task.cancel()
            if poll_task is not None:
                poll_task.cancel()

    async def _poll_chat_messages(
        self, chat_id: str, queue: asyncio.Queue
    ) -> None:
        """Fallback: poll im.v1.message.list every 2 s for ``chat_id``.

        Lark does not deliver im.message.receive_v1 events for messages
        a bot posts itself — the gate script's /new-thread POST happens
        exactly that way. This loop bridges the gap: fresh messages
        (dedup by message_id) synthesise ``msg_received`` events onto
        the same queue the WS path feeds. Runs in the asyncio loop;
        the Lark REST client is threadsafe enough for our single
        caller.
        """
        import lark_oapi
        from lark_oapi.api.im.v1 import ListMessageRequest

        seen_msg_ids: set[str] = set()
        client = (
            lark_oapi.Client.builder()
            .app_id(self._config.app_id)
            .app_secret(self._config.app_secret)
            .build()
        )

        # First pass: mark existing messages as seen so we only yield new
        # ones. Without this, the adapter would replay the entire chat
        # history on first poll.
        bootstrap = True

        while True:
            try:
                req = (
                    ListMessageRequest.builder()
                    .container_id_type("chat")
                    .container_id(chat_id)
                    .sort_type("ByCreateTimeDesc")
                    .page_size(20)
                    .build()
                )
                resp = await asyncio.get_running_loop().run_in_executor(
                    None, client.im.v1.message.list, req
                )
                if resp.code == 0 and resp.data and resp.data.items:
                    fresh: list[Any] = []
                    for m in resp.data.items:
                        mid = getattr(m, "message_id", None)
                        if not mid:
                            continue
                        if mid in seen_msg_ids:
                            continue
                        seen_msg_ids.add(mid)
                        if not bootstrap:
                            fresh.append(m)
                    for m in reversed(fresh):  # oldest → newest within batch
                        envelope = self._message_to_envelope(m, chat_id)
                        if envelope is None:
                            continue
                        # Lane A (spec §7.1): gate before enqueueing. The
                        # polling path sees bot-self messages too; those
                        # use open_id="ou_mock_bot" or similar app-
                        # identity and will be denied unless an admin
                        # has granted that principal msg.send.
                        sender_open_id = envelope.get("principal_id") or ""
                        if not self._is_authorized(sender_open_id, chat_id):
                            await self._deny_rate_limited(
                                sender_open_id, chat_id
                            )
                            continue
                        await queue.put(envelope)
                    bootstrap = False
            except Exception as exc:  # noqa: BLE001 — poller boundary
                logger.debug("feishu poll error (non-fatal): %s", exc)

            await asyncio.sleep(2.0)

    def _message_to_envelope(
        self, m: Any, chat_id: str
    ) -> dict[str, Any] | None:
        """Convert a Lark Message (from im.v1.message.list) into the
        ``msg_received`` envelope shape the WS path produces."""
        body = getattr(m, "body", None)
        raw_content = getattr(body, "content", "") if body else ""
        msg_type = getattr(m, "msg_type", "") or ""
        extracted = _extract_text(raw_content, msg_type)
        sender = getattr(m, "sender", None)
        sender_open_id = (
            getattr(getattr(sender, "id", None), "open_id", "") if sender else ""
        ) or ""
        return self._build_msg_received_envelope(
            args={
                "chat_id": chat_id,
                # PR-A T1: same ESR instance_id semantics as the WS path
                # in _emit_events_lark.
                "app_id": self.actor_id,
                "message_id": getattr(m, "message_id", "") or "",
                "content": extracted,
                "raw_content": raw_content,
                "msg_type": msg_type,
                "sender_id": sender_open_id,
                "sender_type": getattr(sender, "sender_type", "") if sender else "",
                "thread_id": getattr(m, "thread_id", "") or "",
                "root_id": getattr(m, "root_id", "") or "",
            },
            sender_open_id=sender_open_id,
        )

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
                            sender_open_id = sender_id.get("open_id", "") or ""
                            chat_id = message.get("chat_id", "") or ""
                            # Lane A (spec §7.1): principal must hold
                            # workspace:<name>/msg.send for the chat's
                            # workspace. Unauthorized → one rate-limited
                            # deny DM per 10 min, no event emitted.
                            if not self._is_authorized(sender_open_id, chat_id):
                                await self._deny_rate_limited(
                                    sender_open_id, chat_id
                                )
                                continue
                            yield self._build_msg_received_envelope(
                                args={
                                    "chat_id": chat_id,
                                    # PR-A T1: ESR instance_id (the
                                    # adapters.yaml key); see the
                                    # parallel _emit_events_lark
                                    # comment for the locked semantics.
                                    "app_id": self.actor_id,
                                    "message_id": message.get("message_id", ""),
                                    "content": _extract_text(raw_content, msg_type),
                                    "raw_content": raw_content,
                                    "msg_type": msg_type,
                                    "sender_id": sender_open_id,
                                    "sender_type": sender.get("sender_type", ""),
                                    "thread_id": message.get("thread_id", ""),
                                    "root_id": message.get("root_id", ""),
                                },
                                sender_open_id=sender_open_id,
                            )
                except (aiohttp.ClientError, TimeoutError):
                    # mock_feishu restart-tolerance: back off and retry.
                    await asyncio.sleep(1)
