"""CC tmux adapter entry point (PRD 04 F16-F22).

Launches Claude Code TUI sessions inside tmux and mediates I/O.
Factory is pure (PRD 04 F02) — the tmux availability probe happens
lazily on first directive (F22).

Directives currently implemented:
 - ``new_session`` (F17): ``tmux new-session -d -s <name> <cmd>``

Directive shape (per spec §5.3):
 - Caller invokes ``await adapter.on_directive(action, args)``
 - Returns ``{"ok": bool, "result"?: dict, "error"?: str}``

F18 (send_keys), F19 (kill_session), F20 (capture_pane), F21 (event
monitoring) follow in subsequent commits.
"""

from __future__ import annotations

import logging
import subprocess
from typing import Any

from esr.adapter import AdapterConfig, adapter

logger = logging.getLogger(__name__)

SENTINEL_PREFIX = "[esr-cc] "
"""Marker lines produced by the launched CC process (PRD 04 F21)."""


def parse_sentinel_line(session: str, line: str) -> dict[str, Any] | None:
    """Parse a single tmux output line into a ``cc_output`` event dict.

    Returns ``None`` for non-sentinel lines so the caller can skip
    them cheaply without flooding the event stream with terminal noise.
    """
    # Strip only trailing newline — internal whitespace is significant
    # (handlers may parse structured payloads after the sentinel).
    if line.endswith("\n"):
        line = line[:-1]
    if not line.startswith(SENTINEL_PREFIX):
        return None
    text = line[len(SENTINEL_PREFIX):]
    if not text:
        return None  # bare sentinel with no payload is noise
    return {
        "event_type": "cc_output",
        "args": {"session": session, "text": text},
    }


@adapter(
    name="cc_tmux",
    allowed_io={
        "subprocess": ["tmux"],
    },
)
class CcTmuxAdapter:
    """Adapter instance that owns a set of tmux-hosted CC sessions."""

    def __init__(self, actor_id: str, config: AdapterConfig) -> None:
        self.actor_id = actor_id
        self._config = config
        self._tmux_available: bool | None = None

    @staticmethod
    def factory(actor_id: str, config: AdapterConfig) -> CcTmuxAdapter:
        """Construct a CcTmuxAdapter — pure, no I/O (PRD 04 F02)."""
        return CcTmuxAdapter(actor_id=actor_id, config=config)

    # Expose the parser as a classmethod alias — handy for callers
    # that want to drive line-at-a-time parsing without importing the
    # module-level function.
    parse_line = staticmethod(parse_sentinel_line)

    # --- directive dispatch (F17-F20, F22) ----------------------------

    async def on_directive(
        self, action: str, args: dict[str, Any]
    ) -> dict[str, Any]:
        """Dispatch a directive. Returns {"ok": bool, result?/error?}."""
        if not self._ensure_tmux():
            return {"ok": False, "error": "tmux not installed"}

        if action == "new_session":
            return self._new_session(args)
        if action == "send_keys":
            return self._send_keys(args)
        if action == "kill_session":
            return self._kill_session(args)
        if action == "capture_pane":
            return self._capture_pane(args)
        return {"ok": False, "error": f"unknown action: {action}"}

    def _ensure_tmux(self) -> bool:
        """Probe ``tmux --version`` once; cache the result (F22)."""
        if self._tmux_available is not None:
            return self._tmux_available
        try:
            subprocess.run(
                ["tmux", "--version"], capture_output=True, text=True
            )
            self._tmux_available = True
        except FileNotFoundError:
            logger.warning("tmux not installed; subsequent directives will error")
            self._tmux_available = False
        return self._tmux_available

    def _new_session(self, args: dict[str, Any]) -> dict[str, Any]:
        """Run ``tmux new-session -d -s <session_name> <start_cmd>`` (F17)."""
        session_name = args["session_name"]
        start_cmd = args["start_cmd"]
        result = subprocess.run(
            ["tmux", "new-session", "-d", "-s", session_name, start_cmd],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return {"ok": True}
        return {"ok": False, "error": result.stderr.strip()}

    def _send_keys(self, args: dict[str, Any]) -> dict[str, Any]:
        """Run ``tmux send-keys -t <session_name> <content> Enter`` (F18).

        Content is passed as its own argv element — tmux receives it
        verbatim without shell interpretation, so $vars / backticks /
        quotes inside ``content`` are literal keystrokes.
        """
        session_name = args["session_name"]
        content = args["content"]
        result = subprocess.run(
            ["tmux", "send-keys", "-t", session_name, content, "Enter"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return {"ok": True}
        return {"ok": False, "error": result.stderr.strip()}

    def _kill_session(self, args: dict[str, Any]) -> dict[str, Any]:
        """Run ``tmux kill-session -t <session_name>`` (F19)."""
        session_name = args["session_name"]
        result = subprocess.run(
            ["tmux", "kill-session", "-t", session_name],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return {"ok": True}
        return {"ok": False, "error": result.stderr.strip()}

    def _capture_pane(self, args: dict[str, Any]) -> dict[str, Any]:
        """Run ``tmux capture-pane -t <session_name> -p`` returning pane text (F20)."""
        session_name = args["session_name"]
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", session_name, "-p"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return {"ok": True, "result": {"content": result.stdout}}
        return {"ok": False, "error": result.stderr.strip()}

    # --- event emission (PRD 04 F21) ----------------------------------

    async def emit_events(self):  # type: ignore[no-untyped-def]
        """Poll the bound tmux session's pane for sentinel-prefixed lines.

        The adapter's ``actor_id`` is ``tmux:<thread_id>``; the tmux
        session name is the ``<thread_id>`` part. We poll
        ``tmux capture-pane`` at 500 ms cadence, track which sentinel
        lines we've already emitted (by full-line string), and yield
        each fresh one as a ``cc_output`` event. The async generator
        exits when the tmux session disappears (pane capture returns
        non-zero).
        """
        import asyncio as _asyncio

        session_name = self.actor_id.split(":", 1)[-1] if ":" in self.actor_id else self.actor_id
        seen: set[str] = set()

        while True:
            if not self._ensure_tmux():
                return
            result = subprocess.run(
                ["tmux", "capture-pane", "-t", session_name, "-p"],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                # Session gone — stop emitting; directive dispatch will
                # surface the failure separately.
                return
            for line in result.stdout.splitlines():
                if not line.startswith(SENTINEL_PREFIX):
                    continue
                if line in seen:
                    continue
                seen.add(line)
                parsed = parse_sentinel_line(session_name, line + "\n")
                if parsed is not None:
                    yield parsed

            await _asyncio.sleep(0.5)
