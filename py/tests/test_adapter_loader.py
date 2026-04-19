"""Tests for load_adapter_factory — Phase 8a/8b adapter import resolution."""
from __future__ import annotations

import sys
import types

import pytest

from esr.adapter import ADAPTER_REGISTRY, adapter


@pytest.fixture(autouse=True)
def _clear_adapter_registry() -> None:
    """Each test starts with a clean registry + no residual modules."""
    saved = dict(ADAPTER_REGISTRY)
    ADAPTER_REGISTRY.clear()
    for mod_name in [n for n in sys.modules if n.startswith("esr_stubadapter")]:
        del sys.modules[mod_name]
    yield
    ADAPTER_REGISTRY.clear()
    ADAPTER_REGISTRY.update(saved)


def _install_fake_module(pkg_name: str, adapter_name: str) -> None:
    """Create an in-memory esr_<name> module that registers an adapter."""
    mod = types.ModuleType(pkg_name)

    @adapter(name=adapter_name, allowed_io={})
    class _FakeAdapter:  # noqa: N801 — test fixture
        @staticmethod
        def factory(actor_id: str, config: dict[str, object]) -> _FakeAdapter:
            instance = _FakeAdapter()
            instance.actor_id = actor_id  # type: ignore[attr-defined]
            instance.config = config  # type: ignore[attr-defined]
            return instance

    mod.FakeAdapter = _FakeAdapter  # type: ignore[attr-defined]
    sys.modules[pkg_name] = mod


def test_load_adapter_factory_imports_and_returns_factory() -> None:
    from esr.adapters import load_adapter_factory

    _install_fake_module("esr_stubadapter1", "stubadapter1")
    factory = load_adapter_factory("stubadapter1")
    assert callable(factory)
    instance = factory("actor-42", {"key": "val"})
    assert instance.actor_id == "actor-42"
    assert instance.config == {"key": "val"}


def test_load_adapter_factory_unknown_raises() -> None:
    from esr.adapters import AdapterNotFound, load_adapter_factory

    with pytest.raises(AdapterNotFound) as excinfo:
        load_adapter_factory("this_adapter_does_not_exist")
    assert "this_adapter_does_not_exist" in str(excinfo.value)
