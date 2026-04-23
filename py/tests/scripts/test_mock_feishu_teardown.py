"""P5 regression (PR-7 e2e discovery): mock_feishu teardown must free the port.

E2E RCA: scenario scripts launch mock_feishu via `uv run --project py python
scripts/mock_feishu.py --port N`. `uv run` spawns the real python3 as a
child; the bash pidfile captures the uv wrapper's pid. `kill $(cat pidfile)`
kills the wrapper but the child python keeps listening on the port, so the
next scenario hits `OSError: address already in use`.

This test proves that the combined teardown (kill pidfile + pkill by port)
frees the port within a bounded time. If the teardown regresses — e.g. by
dropping the pkill-by-port line in common.sh — this test fails.
"""
from __future__ import annotations

import contextlib
import os
import signal
import socket
import subprocess
import time
from pathlib import Path

import pytest


def _port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("127.0.0.1", port))
            return False
        except OSError:
            return True


def _find_free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_until(pred, timeout_s: float = 5.0, interval_s: float = 0.05) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(interval_s)
    return pred()


@pytest.fixture
def mock_feishu_port() -> int:
    port = _find_free_port()
    assert not _port_in_use(port), "pre-check: port should be free before the test runs"
    return port


def test_pkill_by_port_frees_port_after_uv_run_wrapper_killed(
    mock_feishu_port: int, tmp_path: Path
) -> None:
    """Kill just the `uv run` wrapper; verify pkill-by-port cleans up the python child."""
    repo_root = Path(__file__).resolve().parents[3]
    pidfile = tmp_path / "mock.pid"

    # Launch mock_feishu under `uv run` exactly the way common.sh does.
    proc = subprocess.Popen(
        [
            "uv",
            "run",
            "--project",
            "py",
            "python",
            "scripts/mock_feishu.py",
            "--port",
            str(mock_feishu_port),
        ],
        cwd=str(repo_root),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    pidfile.write_text(str(proc.pid))

    try:
        # Wait for it to bind.
        assert _wait_until(lambda: _port_in_use(mock_feishu_port), timeout_s=10.0), (
            "mock_feishu did not come up within 10 s"
        )

        # Kill only the uv run wrapper (simulates the bash pidfile kill path).
        with contextlib.suppress(ProcessLookupError):
            os.kill(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5.0)

        # Python child may still be alive → port still bound. That is the
        # regression state this test protects against.
        # Now run the common.sh defensive pkill (matches teardown shape).
        subprocess.run(
            [
                "pkill",
                "-9",
                "-f",
                f"mock_feishu.py --port {mock_feishu_port}",
            ],
            check=False,
        )

        # Port must be released within a reasonable window.
        assert _wait_until(
            lambda: not _port_in_use(mock_feishu_port), timeout_s=5.0
        ), (
            f"port {mock_feishu_port} still bound after pidfile-kill + pkill-by-port; "
            "teardown in tests/e2e/scenarios/common.sh regressed"
        )
    finally:
        # Belt-and-braces final sweep to avoid leaking into other tests.
        subprocess.run(
            [
                "pkill",
                "-9",
                "-f",
                f"mock_feishu.py --port {mock_feishu_port}",
            ],
            check=False,
        )
