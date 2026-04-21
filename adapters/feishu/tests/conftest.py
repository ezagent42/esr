"""Shared fixtures for the Feishu adapter test suite.

Lane A (spec §7.1) — the adapter drops any inbound message whose
principal doesn't hold ``workspace:<name>/msg.send`` for the chat's
workspace. Pre-existing emit-events tests exercise the inbound paths
with synthetic sender ids that aren't listed in any capabilities.yaml;
they need a permissive CapabilitiesChecker to keep working.

The ``allow_all_capabilities`` fixture writes a temporary
``capabilities.yaml`` granting ``["*"]`` to a set of principals the
tests send from. Tests that want to exercise Lane A enforcement
itself (``test_lane_a.py``) opt out by building their own yaml.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml


def write_allow_all_capabilities(
    path: Path,
    principals: list[str] | None = None,
) -> Path:
    """Write a ``capabilities.yaml`` at ``path`` granting ``*`` to each
    principal in ``principals`` (default: the sender ids used by the
    pre-existing emit-events + envelope tests).

    Returns ``path`` for convenience.
    """
    principals = principals or [
        "ou_sender_1",  # test_emit_events.py
        "ou_alice",  # test_envelope_principal.py
        "ou_test",  # mock_feishu.seed_inbound_message default
    ]
    doc = {
        "principals": [
            {"id": pid, "kind": "feishu_user", "capabilities": ["*"]}
            for pid in principals
        ]
    }
    path.write_text(yaml.safe_dump(doc, sort_keys=False))
    return path


@pytest.fixture
def allow_all_capabilities(tmp_path: Path) -> Path:
    """Return a path to a tmp capabilities.yaml that grants ``*`` to
    every principal the pre-existing tests use. Inject into
    ``AdapterConfig({..., "capabilities_path": str(allow_all_capabilities)})``.
    """
    return write_allow_all_capabilities(tmp_path / "capabilities.yaml")
