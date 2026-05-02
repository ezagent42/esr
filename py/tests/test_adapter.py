"""PRD 02 F07 / F08 — @adapter decorator + AdapterConfig."""

from __future__ import annotations

from collections.abc import Iterator

import pytest

from esr.adapter import ADAPTER_REGISTRY, AdapterConfig, adapter


@pytest.fixture(autouse=True)
def _isolate_registry() -> Iterator[None]:
    """Save, clear, and restore ADAPTER_REGISTRY around every test.

    Restoring is important: real adapter packages (esr_feishu,
    esr_cc_mcp) register themselves at import time, and other
    test files depend on those entries existing. Clearing without
    restoring would break cross-file test order.
    """
    saved = dict(ADAPTER_REGISTRY)
    ADAPTER_REGISTRY.clear()
    try:
        yield
    finally:
        ADAPTER_REGISTRY.clear()
        ADAPTER_REGISTRY.update(saved)


# --- PRD 02 F07: @adapter decorator -------------------------------------


def test_adapter_registers_class() -> None:
    """Decorated class appears in ADAPTER_REGISTRY under `name`."""

    @adapter(name="feishu", allowed_io={"lark_oapi": "*", "aiohttp": "*"})
    class FeishuAdapter:
        @staticmethod
        def factory(actor_id: str, config: AdapterConfig) -> FeishuAdapter:
            return FeishuAdapter()

    assert "feishu" in ADAPTER_REGISTRY
    entry = ADAPTER_REGISTRY["feishu"]
    assert entry.name == "feishu"
    assert entry.cls is FeishuAdapter
    assert entry.allowed_io == {"lark_oapi": "*", "aiohttp": "*"}


def test_adapter_without_factory_rejected() -> None:
    """A class without a static `factory` method is rejected."""

    with pytest.raises(TypeError, match=r"must define a static factory"):

        @adapter(name="broken", allowed_io={})
        class _NoFactory:
            pass


def test_adapter_duplicate_name_rejected() -> None:
    """Duplicate adapter names raise ValueError."""

    @adapter(name="dup", allowed_io={})
    class _First:
        @staticmethod
        def factory(actor_id: str, config: AdapterConfig) -> _First:
            return _First()

    with pytest.raises(ValueError, match=r"adapter dup already registered"):

        @adapter(name="dup", allowed_io={})
        class _Second:
            @staticmethod
            def factory(actor_id: str, config: AdapterConfig) -> _Second:
                return _Second()


def test_adapter_requires_keyword_args() -> None:
    """name + allowed_io must be keyword-only."""
    with pytest.raises(TypeError):
        adapter("x", {})  # type: ignore[call-arg,misc]


# --- PRD 02 F08: AdapterConfig ------------------------------------------


def test_adapter_config_attr_access() -> None:
    """Dict-backed config exposes keys as attributes."""
    cfg = AdapterConfig({"app_id": "cli_abc", "app_secret": "secret"})
    assert cfg.app_id == "cli_abc"
    assert cfg.app_secret == "secret"


def test_adapter_config_unknown_attr_raises() -> None:
    """Missing key → AttributeError, not KeyError."""
    cfg = AdapterConfig({"app_id": "cli_abc"})
    with pytest.raises(AttributeError, match=r"missing"):
        _ = cfg.does_not_exist


def test_adapter_config_is_readonly() -> None:
    """Setting an attribute on AdapterConfig raises."""
    cfg = AdapterConfig({"app_id": "cli_abc"})
    with pytest.raises(AttributeError, match=r"read-only"):
        cfg.app_id = "other"  # type: ignore[misc]


def test_adapter_config_private_fields_not_exposed() -> None:
    """Dunder / underscore keys in the wrapped dict are not accessible."""
    cfg = AdapterConfig({"_hidden": "x"})
    with pytest.raises(AttributeError):
        _ = cfg._hidden
