"""PRD 02 F17 — frozen-state harness."""

from __future__ import annotations

import pytest
from pydantic import BaseModel, ValidationError

from esr.verify.purity import frozen_state_fixture


class _ExampleState(BaseModel):
    model_config = {"frozen": True}
    counter: int = 0
    label: str = "default"


class _NonFrozenState(BaseModel):
    counter: int = 0  # no frozen=True in model_config


def test_frozen_state_fixture_constructs_instance() -> None:
    """Returns an instance of the given pydantic model."""
    s = frozen_state_fixture(_ExampleState)
    assert isinstance(s, _ExampleState)
    assert s.counter == 0
    assert s.label == "default"


def test_frozen_state_fixture_accepts_kwargs() -> None:
    """Caller can override defaults via kwargs."""
    s = frozen_state_fixture(_ExampleState, counter=7, label="hello")
    assert s.counter == 7
    assert s.label == "hello"


def test_frozen_state_fixture_mutation_raises() -> None:
    """Mutation of a frozen instance raises pydantic ValidationError."""
    s = frozen_state_fixture(_ExampleState)
    with pytest.raises(ValidationError):
        s.counter = 1


def test_frozen_state_fixture_rejects_non_frozen_model() -> None:
    """Fixture refuses to build a non-frozen model — surfaces mis-config."""
    with pytest.raises(TypeError, match=r"must be frozen"):
        frozen_state_fixture(_NonFrozenState)
