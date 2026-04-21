"""PRD 04 F03 — feishu adapter I/O-permission scan."""

from __future__ import annotations

from pathlib import Path

from esr.verify.io_permission import scan_adapter

_ADAPTER_DIR = Path(__file__).resolve().parents[1]


def test_feishu_adapter_io_permission_scan_clean() -> None:
    """Scanning esr_feishu.adapter against its declared allowed_io is clean."""
    import esr_feishu.adapter  # noqa: F401 — ensure registration

    from esr.adapter import ADAPTER_REGISTRY

    entry = ADAPTER_REGISTRY["feishu"]
    src = _ADAPTER_DIR / "src" / "esr_feishu" / "adapter.py"
    violations = scan_adapter(src, entry.allowed_io)
    assert violations == [], f"unexpected violations: {violations!r}"
