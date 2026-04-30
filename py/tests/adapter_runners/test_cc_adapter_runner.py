"""Tests for the ``cc_adapter_runner`` sidecar (PR-4b P4b-3).

cc_adapter_runner hosts both ``cc_tmux`` and ``cc_mcp``; allowlist must
accept both while rejecting Feishu.
"""
from __future__ import annotations

import os
import subprocess
import sys


def test_cc_adapter_runner_help_exits_clean() -> None:
    # PR-21β: ESR_SPAWN_TOKEN guard requires a token for CLI invocation.
    env = {**os.environ, "ESR_SPAWN_TOKEN": "__debug__"}
    result = subprocess.run(
        [sys.executable, "-m", "cc_adapter_runner", "--help"],
        capture_output=True, text=True, timeout=10, env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "--adapter" in result.stdout
    assert "cc_adapter_runner" in result.stdout


def test_cc_adapter_runner_accepts_cc_tmux() -> None:
    from cc_adapter_runner.__main__ import main

    exit_code = main([
        "--adapter", "cc_tmux",
        "--instance-id", "c1",
        "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket",
        "--config-json", '{"start_cmd": "scripts/mock_cc.py"}',
        "--dry-run",
    ])
    assert exit_code == 0


def test_cc_adapter_runner_accepts_cc_mcp() -> None:
    from cc_adapter_runner.__main__ import main

    exit_code = main([
        "--adapter", "cc_mcp",
        "--instance-id", "m1",
        "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket",
        "--config-json", "{}",
        "--dry-run",
    ])
    assert exit_code == 0


def test_cc_adapter_runner_rejects_feishu() -> None:
    from cc_adapter_runner.__main__ import main

    exit_code = main([
        "--adapter", "feishu",
        "--instance-id", "f1",
        "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket",
        "--config-json", "{}",
        "--dry-run",
    ])
    assert exit_code == 2
