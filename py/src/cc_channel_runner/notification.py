"""Build MCP `notifications/claude/channel` params from a broadcast envelope.

Python port of `Esr.Plugins.ClaudeCode.ChannelNotification.build_notification_params/1`
(runtime/lib/esr/plugins/claude_code/channel_notification.ex) for the
stdio bridge.

Deviation from the Elixir helper (per plan Task 2.4 step 2):

- PhaserRegistry resolution is skipped. The Elixir helper resolves
  `media_uri` to a local filesystem `path` via `PhaserRegistry.transform/2`
  before stuffing it into meta. The bridge runs in CC's process — it
  has no BEAM Phaser registry to call into. Until a bridge-side
  resolver lands, we forward `media_uri` + `msg_type` through as meta
  fields and CC tooling resolves them as URIs.

Spec: docs/superpowers/specs/2026-05-13-cc-channel-stdio-bridge-design.md
"""

from __future__ import annotations

from typing import Any

# Meta fields surfaced to CC. Order doesn't matter (JSON object), but
# keeping the tuple aligned with `take_meta/1` in Elixir aids audit.
_META_FIELDS = (
    "chat_id",
    "app_id",
    "message_id",
    "user",
    "ts",
    "thread_id",
    "runtime_mode",
    "source",
    "user_id",
    "workspace",
)

_ATTACHMENT_KINDS = ("image", "file", "audio")


def build_notification_params(payload: dict[str, Any]) -> dict[str, Any]:
    """Translate a broadcast envelope into MCP notification params.

    For text envelopes (msg_type absent or "text"): passes `content`
    + meta through unchanged.

    For attachment envelopes (msg_type in image/file/audio with a
    media_uri): replaces content with a `[<kind> attachment]` stub
    and surfaces `kind` + `media_uri` in meta. Until Python-side
    phaser resolution is wired, the `path` field that Elixir produces
    is absent; CC tooling sees `meta.media_uri` instead.
    """
    msg_type = payload.get("msg_type")
    media_uri = payload.get("media_uri")

    if msg_type in _ATTACHMENT_KINDS and isinstance(media_uri, str) and media_uri:
        return _build_attachment_params(payload, msg_type, media_uri)
    return _build_text_params(payload)


def _build_text_params(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "content": payload.get("content") or "",
        "meta": _take_meta(payload),
    }


def _build_attachment_params(
    payload: dict[str, Any], kind: str, uri: str
) -> dict[str, Any]:
    meta = _take_meta(payload)
    meta["kind"] = kind
    # No phaser → surface the raw URI. CC-side helpers resolve it.
    meta["media_uri"] = uri
    return {
        "content": f"[{kind} attachment]",
        "meta": meta,
    }


def _take_meta(payload: dict[str, Any]) -> dict[str, str]:
    """Extract user-visible meta fields.

    - Excludes internal routing fields (`msg_type`, `media_uri`,
      `content`, `kind`).
    - Drops nil + empty-string values.
    - Coerces remaining values to string (matches Elixir
      `to_string/1` behavior for the meta payload).
    - Applies defaults: `runtime_mode` → "discussion",
      `source` → "feishu" (mirrors Elixir helper).
    """
    out: dict[str, str] = {}
    for key in _META_FIELDS:
        val = payload.get(key)
        if key == "runtime_mode" and (val is None or val == ""):
            val = "discussion"
        elif key == "source" and (val is None or val == ""):
            val = "feishu"
        if val is None or val == "":
            continue
        out[key] = str(val)
    return out
