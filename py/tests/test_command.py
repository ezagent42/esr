"""PRD 02 F09 — @command decorator."""

from __future__ import annotations

import pytest

from esr.command import COMMAND_REGISTRY, command


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    """Ensure each test starts with a clean COMMAND_REGISTRY."""
    COMMAND_REGISTRY.clear()


def test_command_registers_function() -> None:
    """Decorated function appears in COMMAND_REGISTRY under `name`."""

    @command("feishu-to-cc")
    def build() -> None:
        return None

    assert "feishu-to-cc" in COMMAND_REGISTRY
    entry = COMMAND_REGISTRY["feishu-to-cc"]
    assert entry.name == "feishu-to-cc"
    assert entry.fn is build


def test_command_returns_original_callable() -> None:
    """Decorator returns the function unchanged."""

    @command("x")
    def build() -> int:
        return 42

    assert build() == 42


def test_command_duplicate_name_raises() -> None:
    """Re-registering a command name raises ValueError."""

    @command("dup")
    def _first() -> None:
        return None

    with pytest.raises(ValueError, match=r"command dup already registered"):

        @command("dup")
        def _second() -> None:
            return None


def test_command_entry_is_frozen() -> None:
    """CommandEntry is a frozen dataclass — mutation raises."""
    from esr.command import CommandEntry

    entry = CommandEntry(name="a", fn=lambda: None)
    with pytest.raises(Exception):  # noqa: B017
        entry.name = "other"  # type: ignore[misc]
