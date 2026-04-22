"""Unit tests for ``esr notify`` CLI wrapper (plan DI-13 Task 29).

The wrapper is a thin shell over ``esr admin submit notify ...`` — tests
verify the pending queue file shape so no running esrd is required.
Fire-and-forget semantics are baked in (``--wait`` is not exposed),
matching the post-merge git hook's use case.
"""
from __future__ import annotations

import yaml
from click.testing import CliRunner

from esr.cli.main import cli


def _invoke_notify(
    tmp_path, monkeypatch, extra_args: list[str]
) -> tuple[int, str, dict | None]:
    """Helper: run ``esr notify [extra_args]`` and return
    (exit_code, output, pending_doc_or_None).

    Returns ``None`` for the doc when no pending file was written
    (e.g. when argument validation fails before the submit step).
    """
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    (tmp_path / "default" / "admin_queue" / "pending").mkdir(parents=True)

    runner = CliRunner()
    result = runner.invoke(cli, ["notify", *extra_args])

    pending = list(
        (tmp_path / "default" / "admin_queue" / "pending").glob("*.yaml")
    )
    doc = yaml.safe_load(pending[0].read_text()) if pending else None
    return result.exit_code, result.output, doc


def test_notify_breaking_writes_command_file(monkeypatch, tmp_path):
    """``esr notify --type=breaking --since=abc --details=...`` →
    kind=notify with all three args present."""
    exit_code, output, doc = _invoke_notify(
        tmp_path,
        monkeypatch,
        [
            "--type=breaking",
            "--since=abc123",
            "--details=f00ba12 feat!: drop v1 api",
        ],
    )

    assert exit_code == 0, output
    assert doc is not None, output
    assert doc["kind"] == "notify"
    assert doc["args"] == {
        "type": "breaking",
        "since": "abc123",
        "details": "f00ba12 feat!: drop v1 api",
    }
    assert doc["id"].startswith("01")  # ULID prefix in 2026


def test_notify_requires_type(monkeypatch, tmp_path):
    """``esr notify`` without ``--type`` → click usage error, no queue
    file written."""
    exit_code, output, doc = _invoke_notify(tmp_path, monkeypatch, [])

    assert exit_code != 0, output
    assert doc is None, f"no file should be written, got {doc!r}"
    # click emits "Missing option '--type'" to stderr when a required
    # option is absent — mixed into ``output`` by CliRunner.
    assert "--type" in output


def test_notify_info_with_to(monkeypatch, tmp_path):
    """``esr notify --type=info --to=ou_XXXX --details='hello'`` →
    args include to but no since."""
    exit_code, output, doc = _invoke_notify(
        tmp_path,
        monkeypatch,
        ["--type=info", "--to=ou_XXXX", "--details=hello"],
    )

    assert exit_code == 0, output
    assert doc is not None, output
    assert doc["kind"] == "notify"
    assert doc["args"] == {
        "type": "info",
        "to": "ou_XXXX",
        "details": "hello",
    }
    assert "since" not in doc["args"]


def test_notify_reload_complete_minimal(monkeypatch, tmp_path):
    """``esr notify --type=reload-complete`` with no other args → only
    ``type`` present; the dispatcher fans out to the admin list."""
    exit_code, output, doc = _invoke_notify(
        tmp_path, monkeypatch, ["--type=reload-complete"]
    )

    assert exit_code == 0, output
    assert doc is not None, output
    assert doc["args"] == {"type": "reload-complete"}
