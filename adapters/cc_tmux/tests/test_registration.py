"""PRD 04 F16 — cc_tmux adapter registration."""

from __future__ import annotations

from esr.adapter import ADAPTER_REGISTRY, AdapterConfig


def test_cc_tmux_adapter_registered_on_import() -> None:
    from esr_cc_tmux.adapter import CcTmuxAdapter  # noqa: F401

    assert "cc_tmux" in ADAPTER_REGISTRY
    entry = ADAPTER_REGISTRY["cc_tmux"]
    assert entry.name == "cc_tmux"
    assert entry.cls.__name__ == "CcTmuxAdapter"


def test_cc_tmux_adapter_declares_subprocess_io() -> None:
    import esr_cc_tmux.adapter  # noqa: F401

    entry = ADAPTER_REGISTRY["cc_tmux"]
    assert "subprocess" in entry.allowed_io


def test_cc_tmux_factory_returns_instance() -> None:
    from esr_cc_tmux.adapter import CcTmuxAdapter

    cfg = AdapterConfig({"start_cmd": "/usr/bin/claude"})
    instance = CcTmuxAdapter.factory("cc-local", cfg)
    assert isinstance(instance, CcTmuxAdapter)
    assert instance.actor_id == "cc-local"
