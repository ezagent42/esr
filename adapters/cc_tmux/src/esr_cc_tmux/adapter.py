"""CC tmux adapter entry point (PRD 04 F16-F22).

Launches Claude Code TUI sessions inside tmux and mediates I/O.
Factory is pure (PRD 04 F02) — the tmux availability probe happens
lazily on first directive (F22).

Directive + event implementations land in F17-F21:
 - new_session / send_keys / kill_session / capture_pane directives
 - sentinel-line output monitoring as events
"""

from __future__ import annotations

from esr.adapter import AdapterConfig, adapter


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
