"""PRD 04 F06 — feishu lark client lazy init."""

from __future__ import annotations

from esr.adapter import AdapterConfig


def test_lark_client_is_none_after_factory() -> None:
    """factory() does not build the lark client — stays None."""
    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared", AdapterConfig({"app_id": "cli_a", "app_secret": "s"})
    )
    assert instance._lark_client is None


def test_first_client_call_builds_and_caches() -> None:
    """The first call to client() builds a lark_oapi.Client; subsequent calls reuse it."""
    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared", AdapterConfig({"app_id": "cli_a", "app_secret": "s"})
    )

    c1 = instance.client()
    assert c1 is not None
    assert instance._lark_client is c1

    c2 = instance.client()
    assert c2 is c1  # same object — cached


def test_client_is_lark_client_instance() -> None:
    """Built client is a lark_oapi.Client (not a stub or wrapper)."""
    import lark_oapi

    from esr_feishu.adapter import FeishuAdapter

    instance = FeishuAdapter.factory(
        "feishu-shared",
        AdapterConfig({"app_id": "cli_from_config", "app_secret": "s-from-config"}),
    )
    client = instance.client()
    assert isinstance(client, lark_oapi.Client)
