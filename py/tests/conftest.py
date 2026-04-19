"""Root conftest for py/tests.

Phase 8c skeleton: ``esrd_fixture`` yields a handle that Phase 8c iterates
to actually bring up an in-test esrd subprocess. Today it is a minimal
namespace object so LG-9 passes (the signature is in the test function).
"""
from __future__ import annotations

from dataclasses import dataclass

import pytest


@dataclass
class EsrdHandle:
    """Placeholder; Phase 8c replaces with a real esrd-subprocess wrapper."""
    instance: str = "test"

    def run_cli(self, argv: list[str]) -> object:
        raise RuntimeError(
            "EsrdHandle.run_cli not yet wired in Phase 8c — skeleton only"
        )


@pytest.fixture
def esrd_fixture() -> EsrdHandle:
    return EsrdHandle()
