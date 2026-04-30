"""Tests for esr.ipc.handler_worker.main — Phase 8d symmetric entry.

Same pattern as adapter_runner.main: `python -m esr.ipc.handler_worker
--module feishu_thread.on_msg --worker-id w1 --url ws://.../handler_hub...`
spawns a worker that joins its topic and processes handler_call
envelopes until cancelled.
"""
from __future__ import annotations

import os
import subprocess
import sys
from typing import Any
from unittest.mock import patch


def test_handler_worker_main_parses_args() -> None:
    from esr.ipc.handler_worker import _parse_main_args

    ns = _parse_main_args([
        "--module", "feishu_thread.on_msg",
        "--worker-id", "w-1",
        "--url", "ws://127.0.0.1:4001/handler_hub/socket/websocket?vsn=2.0.0",
    ])
    assert ns.module == "feishu_thread.on_msg"
    assert ns.worker_id == "w-1"
    assert "handler_hub" in ns.url


def test_handler_worker_main_invokes_run() -> None:
    from esr.ipc import handler_worker

    called_with: dict[str, Any] = {}

    async def fake_run(handler_module: str, worker_id: str, url: str) -> None:
        called_with.update(module=handler_module, worker_id=worker_id, url=url)

    with patch.object(handler_worker, "run", new=fake_run):
        exit_code = handler_worker.main([
            "--module", "cc_session.on_msg",
            "--worker-id", "w-42",
            "--url", "ws://127.0.0.1:4001/handler_hub/socket/websocket",
        ])
    assert exit_code == 0
    assert called_with["module"] == "cc_session.on_msg"
    assert called_with["worker_id"] == "w-42"


def test_handler_worker_cli_module_runnable() -> None:
    # PR-21β: ESR_SPAWN_TOKEN guard requires a token for CLI invocation.
    env = {**os.environ, "ESR_SPAWN_TOKEN": "__debug__"}
    result = subprocess.run(
        [sys.executable, "-m", "esr.ipc.handler_worker", "--help"],
        capture_output=True, text=True, timeout=10, env=env,
    )
    assert result.returncode == 0, result.stderr
    assert "--module" in result.stdout
    assert "--worker-id" in result.stdout
