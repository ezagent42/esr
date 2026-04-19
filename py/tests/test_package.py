"""PRD 02 F01 — package skeleton smoke test."""

from __future__ import annotations


def test_esr_imports_and_reports_version() -> None:
    """`import esr; esr.__version__` should equal 0.1.0."""
    import esr

    assert esr.__version__ == "0.1.0"


def test_subpackages_import() -> None:
    """Each declared subpackage is importable."""
    import esr.cli  # noqa: F401
    import esr.ipc  # noqa: F401
    import esr.verify  # noqa: F401
