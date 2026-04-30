"""PR-21β 2026-04-30 — verify the ESR_SPAWN_TOKEN guard in each
Python entry point that esrd spawns.

Each guard fires only when the entry point is invoked as a script
(``python -m <module>``); imports of ``main`` from the module
remain unguarded so existing in-process tests aren't broken.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON = REPO_ROOT / "py" / ".venv" / "bin" / "python"


@pytest.fixture
def env_no_token() -> dict[str, str]:
    """Environment without ESR_SPAWN_TOKEN. Includes PATH so python finds itself."""
    e = {k: v for k, v in os.environ.items() if k != "ESR_SPAWN_TOKEN"}
    return e


GUARDED_MODULES = [
    "feishu_adapter_runner",
    "cc_adapter_runner",
    "generic_adapter_runner",
    "esr.ipc.handler_worker",
]


@pytest.mark.parametrize("module", GUARDED_MODULES)
def test_missing_token_exits_with_status_2(module: str, env_no_token: dict[str, str]) -> None:
    """Without ESR_SPAWN_TOKEN, the entry point must refuse to start."""
    result = subprocess.run(
        [str(PYTHON), "-m", module],
        env=env_no_token,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT / "py",
    )

    assert result.returncode == 2, (
        f"{module}: expected exit 2, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "esrd" in result.stderr
    assert "erlexec" in result.stderr
    assert "manual `uv run`" in result.stderr


@pytest.mark.parametrize("module", GUARDED_MODULES)
def test_debug_token_passes_guard(module: str, env_no_token: dict[str, str]) -> None:
    """ESR_SPAWN_TOKEN=__debug__ must let the entry point past the guard.

    The process will fail later (missing args / can't connect to a real
    URL), but with a different error path than the guard's exit-2.
    """
    env = {**env_no_token, "ESR_SPAWN_TOKEN": "__debug__"}
    result = subprocess.run(
        [str(PYTHON), "-m", module],
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        cwd=REPO_ROOT / "py",
    )

    # Must NOT contain the guard's specific error text.
    assert "must be spawned by esrd via erlexec" not in result.stderr, (
        f"{module}: guard should have allowed __debug__ token, but stderr says:\n"
        f"{result.stderr}"
    )


@pytest.mark.parametrize("module", GUARDED_MODULES)
def test_random_token_passes_guard(module: str, env_no_token: dict[str, str]) -> None:
    """Any non-empty token (not just __debug__) is accepted — the guard
    is fail-fast presence check, not validation."""
    env = {**env_no_token, "ESR_SPAWN_TOKEN": "abcd1234efgh5678"}
    result = subprocess.run(
        [str(PYTHON), "-m", module],
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        cwd=REPO_ROOT / "py",
    )

    assert "must be spawned by esrd via erlexec" not in result.stderr


@pytest.mark.parametrize(
    "module",
    [
        "feishu_adapter_runner.__main__",
        "cc_adapter_runner.__main__",
        "generic_adapter_runner.__main__",
        "esr.ipc.handler_worker",
    ],
)
def test_module_can_still_be_imported(module: str) -> None:
    """`from <module> import main` must not trigger the guard.

    The guard lives inside `if __name__ == "__main__":`, so importing
    the module to call `main(...)` programmatically (which existing
    tests do, e.g. test_dispatch_allowlist.py) must succeed.
    """
    env = {k: v for k, v in os.environ.items() if k != "ESR_SPAWN_TOKEN"}
    result = subprocess.run(
        [
            str(PYTHON),
            "-c",
            f"import {module}; print('imported ok')",
        ],
        env=env,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT / "py",
    )

    assert result.returncode == 0, (
        f"{module}: import should not trigger the guard.\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "imported ok" in result.stdout
