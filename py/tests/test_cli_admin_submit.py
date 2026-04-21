"""Unit test for ``esr admin submit`` (plan DI-7 Task 13).

Verifies the atomic queue-writer primitive: writes a YAML doc under
``<ESRD_HOME>/<instance>/admin_queue/pending/<ULID>.yaml`` with the
expected shape, and the submitted ``id`` is a ULID (begins with ``01`` in
2026 per Crockford-base32 ULID timestamp prefix).
"""
from pathlib import Path  # noqa: F401 — imported for parity with plan stub

import yaml
from click.testing import CliRunner

from esr.cli.main import cli


def test_submit_writes_pending_file(monkeypatch, tmp_path):
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    (tmp_path / "default" / "admin_queue" / "pending").mkdir(parents=True)

    runner = CliRunner()
    result = runner.invoke(
        cli,
        [
            "admin",
            "submit",
            "notify",
            "--arg",
            "to=ou_test",
            "--arg",
            "text=hello",
        ],
    )
    assert result.exit_code == 0, result.output

    pending = list((tmp_path / "default" / "admin_queue" / "pending").glob("*.yaml"))
    assert len(pending) == 1
    doc = yaml.safe_load(pending[0].read_text())
    assert doc["kind"] == "notify"
    assert doc["args"]["to"] == "ou_test"
    assert doc["args"]["text"] == "hello"
    assert "id" in doc
    assert doc["id"].startswith("01")  # ULID prefix in 2026
