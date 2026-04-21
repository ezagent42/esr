"""PRD 04 F05 — feishu adapter registration."""

from __future__ import annotations

from esr.adapter import ADAPTER_REGISTRY, AdapterConfig


def test_feishu_adapter_registered_on_import() -> None:
    """Importing esr_feishu.adapter registers FeishuAdapter in ADAPTER_REGISTRY."""
    from esr_feishu.adapter import FeishuAdapter  # noqa: F401 — side-effect import

    assert "feishu" in ADAPTER_REGISTRY
    entry = ADAPTER_REGISTRY["feishu"]
    assert entry.name == "feishu"
    assert entry.cls.__name__ == "FeishuAdapter"


def test_feishu_adapter_declares_allowed_io() -> None:
    """allowed_io must list lark_oapi + http scope so I/O-permission scan passes."""
    import esr_feishu.adapter  # noqa: F401

    entry = ADAPTER_REGISTRY["feishu"]
    assert "lark_oapi" in entry.allowed_io
    assert "http" in entry.allowed_io


def test_feishu_factory_returns_instance() -> None:
    """factory(actor_id, config) returns a FeishuAdapter instance."""
    from esr_feishu.adapter import FeishuAdapter

    cfg = AdapterConfig({"app_id": "cli_test", "app_secret": "secret"})
    instance = FeishuAdapter.factory("feishu-shared", cfg)
    assert isinstance(instance, FeishuAdapter)
    assert instance.actor_id == "feishu-shared"
