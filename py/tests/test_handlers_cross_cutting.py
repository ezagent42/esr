"""PRD 05 F03 / F04 / F05 — cross-cutting handler invariants.

Instead of eight tiny identical files (test_state_frozen.py +
test_purity.py × 4 handlers), this single file parametrises the three
per-handler checks over every installed handler. Equivalent coverage,
far less duplication — each FR is explicitly labelled in the test
docstrings for PRD traceability.
"""

from __future__ import annotations

import importlib
from pathlib import Path

import pytest
from pydantic import BaseModel, ValidationError

from esr.verify.purity import scan_imports

_REPO_ROOT = Path(__file__).resolve().parents[2]

HANDLERS = ("feishu_app", "feishu_thread", "tmux_proxy", "cc_session")


def _state_class(name: str) -> type[BaseModel]:
    mod = importlib.import_module(f"esr_handler_{name}.state")
    # Each state module defines exactly one subclass of BaseModel
    for attr in vars(mod).values():
        if isinstance(attr, type) and issubclass(attr, BaseModel) and attr is not BaseModel:
            return attr
    raise AssertionError(f"no BaseModel subclass in esr_handler_{name}.state")


# --- PRD 05 F03: state model frozen ------------------------------------


@pytest.mark.parametrize("name", HANDLERS)
def test_state_mutation_raises_validation_error(name: str) -> None:
    """Direct attribute assignment on any handler state → ValidationError."""
    cls = _state_class(name)
    inst = cls()
    # Try the first field; every model has at least one.
    first_field = next(iter(cls.model_fields))
    with pytest.raises(ValidationError):
        setattr(inst, first_field, "anything")


# --- PRD 05 F04: purity check 1 (import allow-list) --------------------


@pytest.mark.parametrize("name", HANDLERS)
def test_handler_module_import_scan_clean(name: str) -> None:
    """Handler on_msg module passes the esr-lint import allow-list."""
    path = (
        _REPO_ROOT
        / "handlers"
        / name
        / "src"
        / f"esr_handler_{name}"
        / "on_msg.py"
    )
    # Handlers legitimately import their own state module, so widen the
    # allow-list with that single package name.
    violations = scan_imports(path, extra_allowed={f"esr_handler_{name}"})
    assert violations == [], f"{name} purity violations: {violations!r}"


@pytest.mark.parametrize("name", HANDLERS)
def test_handler_state_module_import_scan_clean(name: str) -> None:
    """Handler state module passes the esr-lint import allow-list."""
    path = (
        _REPO_ROOT
        / "handlers"
        / name
        / "src"
        / f"esr_handler_{name}"
        / "state.py"
    )
    violations = scan_imports(path)
    assert violations == [], f"{name}.state purity violations: {violations!r}"


# --- PRD 05 F05: purity check 2 (frozen-state invocation) --------------


@pytest.mark.parametrize("name", HANDLERS)
def test_handler_returns_state_that_still_rejects_mutation(name: str) -> None:
    """Calling on_msg with a frozen state returns a state that is still frozen.

    The invariant: handlers are pure and return new state instances
    (via model_copy); the returned state is a fresh pydantic instance
    with the same frozen contract.
    """
    from esr import Event

    cls = _state_class(name)
    state = cls()
    module = importlib.import_module(f"esr_handler_{name}.on_msg")
    on_msg = module.on_msg

    # Any event — handlers tolerate "unknown" events by returning (state, [])
    new_state, _ = on_msg(state, Event(source="esr://x/y/z", event_type="_probe_", args={}))
    first_field = next(iter(cls.model_fields))
    with pytest.raises(ValidationError):
        setattr(new_state, first_field, "anything")
