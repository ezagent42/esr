"""Tests for the ``feishu_adapter_runner`` sidecar (PR-4b P4b-2).

Three-case shape mirrors what the other two per-type sidecars
(``cc_adapter_runner``, ``generic_adapter_runner``) assert:

1. ``--help`` exits cleanly as a module runnable via ``python -m``.
2. Non-allowlisted adapter (e.g. ``cc_mcp``) is rejected with exit
   code 2 and an explanatory stderr message — *before* any adapter
   factory is loaded.
3. Allowlisted adapter (``feishu``) with ``--dry-run`` returns 0,
   proving the allowlist gate lets valid adapters through.
"""
from __future__ import annotations

import os
import subprocess
import sys


def test_feishu_adapter_runner_help_exits_clean() -> None:
    """``python -m feishu_adapter_runner --help`` prints usage and exits 0.

    PR-21β 2026-04-30: ESR_SPAWN_TOKEN guard requires a token (or
    `__debug__` literal) for CLI invocation. Tests use the debug
    literal — same escape hatch documented in the guard's error
    message.
    """
    env = {**os.environ, "ESR_SPAWN_TOKEN": "__debug__"}
    result = subprocess.run(
        [sys.executable, "-m", "feishu_adapter_runner", "--help"],
        capture_output=True, text=True, timeout=10, env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "--adapter" in result.stdout
    assert "--instance-id" in result.stdout
    # Sidecar program name is surfaced in --help so operators see the
    # correct binary name, not ``_adapter_common.main``.
    assert "feishu_adapter_runner" in result.stdout


def test_feishu_adapter_runner_rejects_wrong_adapter() -> None:
    """--adapter cc_mcp must be rejected with a non-zero exit code."""
    from feishu_adapter_runner.__main__ import main

    exit_code = main([
        "--adapter", "cc_mcp",
        "--instance-id", "i1",
        "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket",
        "--config-json", "{}",
        "--dry-run",
    ])
    assert exit_code == 2


def test_feishu_adapter_runner_accepts_feishu_dry_run() -> None:
    """--adapter feishu --dry-run validates and returns 0 without opening WS."""
    from feishu_adapter_runner.__main__ import main

    exit_code = main([
        "--adapter", "feishu",
        "--instance-id", "f1",
        "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket",
        "--config-json", '{"app_id": "cli_test", "app_secret": "sec"}',
        "--dry-run",
    ])
    assert exit_code == 0
