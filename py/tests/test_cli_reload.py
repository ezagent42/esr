"""Unit tests for ``esr reload`` CLI wrapper (plan DI-12 Task 27).

The wrapper is a thin shell over ``esr admin submit reload ...`` — tests
pass ``--no-wait`` semantics by verifying the pending queue file shape so
no running esrd is required.
"""
from __future__ import annotations

import yaml
from click.testing import CliRunner

from esr.cli.main import cli


def _invoke_reload(tmp_path, monkeypatch, extra_args: list[str]) -> tuple[int, str, dict]:
    """Helper: run ``esr reload [extra_args]`` with --no-wait and return
    (exit_code, output, pending_doc)."""
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    (tmp_path / "default" / "admin_queue" / "pending").mkdir(parents=True)

    runner = CliRunner()
    result = runner.invoke(cli, ["reload", "--no-wait", *extra_args])

    pending = list(
        (tmp_path / "default" / "admin_queue" / "pending").glob("*.yaml")
    )
    assert len(pending) == 1, result.output
    doc = yaml.safe_load(pending[0].read_text())
    return result.exit_code, result.output, doc


def test_reload_no_flags_submits_kind_reload(monkeypatch, tmp_path):
    """``esr reload`` with no flags → kind=reload, empty args."""
    exit_code, output, doc = _invoke_reload(tmp_path, monkeypatch, [])

    assert exit_code == 0, output
    assert doc["kind"] == "reload"
    assert doc["args"] == {}
    assert doc["id"].startswith("01")  # ULID prefix in 2026


def test_reload_acknowledge_breaking_sets_arg(monkeypatch, tmp_path):
    """``esr reload --acknowledge-breaking`` → args.acknowledge_breaking=true."""
    exit_code, output, doc = _invoke_reload(
        tmp_path, monkeypatch, ["--acknowledge-breaking"]
    )

    assert exit_code == 0, output
    assert doc["kind"] == "reload"
    assert doc["args"] == {"acknowledge_breaking": "true"}


def test_reload_dry_run_propagates(monkeypatch, tmp_path):
    """``esr reload --dry-run`` → args.dry_run=true passed through."""
    exit_code, output, doc = _invoke_reload(
        tmp_path, monkeypatch, ["--dry-run"]
    )

    assert exit_code == 0, output
    assert doc["kind"] == "reload"
    assert doc["args"] == {"dry_run": "true"}


def test_reload_both_flags_propagate(monkeypatch, tmp_path):
    """Both flags set → both args present."""
    exit_code, output, doc = _invoke_reload(
        tmp_path, monkeypatch, ["--acknowledge-breaking", "--dry-run"]
    )

    assert exit_code == 0, output
    assert doc["args"] == {
        "acknowledge_breaking": "true",
        "dry_run": "true",
    }
