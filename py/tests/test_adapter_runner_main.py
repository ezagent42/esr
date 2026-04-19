"""Tests for esr.ipc.adapter_runner.main — Phase 8d subprocess entry point.

The scenario's setup steps need to fire-and-forget background adapter
worker processes. Each worker is launched via:

    uv run --project py python -m esr.ipc.adapter_runner \\
        --adapter feishu --instance-id f1 --url <handler_hub_url> \\
        --config-json '{"app_id": "...", "app_secret": "..."}'

This test verifies main() argument parsing + delegates to
``run(adapter_name, instance_id, config, url)``. Actually connecting
to a live esrd is covered by the scenario (integration layer).
"""
from __future__ import annotations

import asyncio
import subprocess
import sys
from typing import Any
from unittest.mock import AsyncMock, patch

import pytest


def test_adapter_runner_main_parses_args() -> None:
    """main(argv) returns the parsed Namespace with adapter, instance_id,
    url, and config dict populated correctly."""
    from esr.ipc.adapter_runner import _parse_main_args

    ns = _parse_main_args([
        "--adapter", "feishu",
        "--instance-id", "f1",
        "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket?vsn=2.0.0",
        "--config-json", '{"app_id": "cli_test", "app_secret": "sec"}',
    ])
    assert ns.adapter == "feishu"
    assert ns.instance_id == "f1"
    assert "adapter_hub" in ns.url
    assert ns.config == {"app_id": "cli_test", "app_secret": "sec"}


def test_adapter_runner_main_invokes_run() -> None:
    """main() wires parsed args into a call to run(...)."""
    from esr.ipc import adapter_runner

    called_with: dict[str, Any] = {}

    async def fake_run(
        adapter_name: str, instance_id: str, config: dict[str, Any], url: str
    ) -> None:
        called_with.update(
            adapter_name=adapter_name,
            instance_id=instance_id,
            config=config,
            url=url,
        )

    with patch.object(adapter_runner, "run", new=fake_run):
        exit_code = adapter_runner.main([
            "--adapter", "cc_tmux",
            "--instance-id", "cc1",
            "--url", "ws://127.0.0.1:4001/adapter_hub/socket/websocket",
            "--config-json", '{"start_cmd": "scripts/mock_cc.py"}',
        ])
    assert exit_code == 0
    assert called_with["adapter_name"] == "cc_tmux"
    assert called_with["instance_id"] == "cc1"
    assert called_with["config"] == {"start_cmd": "scripts/mock_cc.py"}


def test_adapter_runner_cli_module_runnable() -> None:
    """python -m esr.ipc.adapter_runner --help exits cleanly."""
    result = subprocess.run(
        [sys.executable, "-m", "esr.ipc.adapter_runner", "--help"],
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert "--adapter" in result.stdout
    assert "--instance-id" in result.stdout
