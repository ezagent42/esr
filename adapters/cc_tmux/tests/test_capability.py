"""PRD 04 F03 — cc_tmux adapter capability scan."""

from __future__ import annotations

from pathlib import Path

from esr.verify.capability import scan_adapter

_ADAPTER_DIR = Path(__file__).resolve().parents[1]


def test_cc_tmux_adapter_capability_scan_clean() -> None:
    import esr_cc_tmux.adapter  # noqa: F401

    from esr.adapter import ADAPTER_REGISTRY

    entry = ADAPTER_REGISTRY["cc_tmux"]
    src = _ADAPTER_DIR / "src" / "esr_cc_tmux" / "adapter.py"
    violations = scan_adapter(src, entry.allowed_io)
    assert violations == [], f"unexpected violations: {violations!r}"
