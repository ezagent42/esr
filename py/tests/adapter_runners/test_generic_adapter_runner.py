"""Tests for the ``generic_adapter_runner`` catch-all (PR-4b P4b-4).

Semantics to assert:

1. ``--help`` runs (module discoverable via ``python -m``).
2. Any ``--adapter`` value is accepted under ``--dry-run`` (no allowlist).
3. ``_emit_deprecation_warning`` surfaces a :class:`DeprecationWarning`
   with the migration prompt — operators spot misrouted launches.
"""
from __future__ import annotations

import os
import subprocess
import sys
import warnings


def test_generic_adapter_runner_help_exits_clean() -> None:
    # PR-21β: ESR_SPAWN_TOKEN guard requires a token for CLI invocation.
    env = {**os.environ, "ESR_SPAWN_TOKEN": "__debug__"}
    result = subprocess.run(
        [sys.executable, "-m", "generic_adapter_runner", "--help"],
        capture_output=True, text=True, timeout=10, env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "--adapter" in result.stdout
    assert "generic_adapter_runner" in result.stdout


def test_generic_adapter_runner_accepts_any_adapter() -> None:
    """No allowlist → any adapter passes --dry-run validation."""
    from generic_adapter_runner.__main__ import main

    for name in ("feishu", "cc_tmux", "cc_mcp", "some_new_thing"):
        exit_code = main([
            "--adapter", name,
            "--instance-id", "x1",
            "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket",
            "--config-json", "{}",
            "--dry-run",
        ])
        assert exit_code == 0, f"generic runner should accept --adapter {name}"


def test_generic_adapter_runner_emits_deprecation_warning() -> None:
    """Boot-time warning prompts migration to a dedicated sidecar."""
    from generic_adapter_runner.__main__ import _emit_deprecation_warning

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        _emit_deprecation_warning()

    assert len(caught) == 1
    w = caught[0]
    assert issubclass(w.category, DeprecationWarning)
    assert "generic_adapter_runner" in str(w.message)
    assert "allowlist" in str(w.message)
