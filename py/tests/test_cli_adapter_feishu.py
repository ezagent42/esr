"""Unit test for ``esr adapter feishu create-app`` wizard (plan DI-8 Task 15).

Mocks ``_validate_creds`` so no real Feishu HTTP call fires, feeds the
app_id/app_secret via stdin, and verifies the wizard submits a
``register_adapter`` admin command through the pending queue with the
expected shape.

The test uses ``--no-wait`` to skip queue-polling — this CI has no live
esrd dispatcher to move pending/ → completed/ or failed/.

To keep the test hermetic, we monkey-patch ``_HOME_MAP`` so that
``--target-env dev`` points at ``tmp_path`` instead of the operator's
real ``~/.esrd-dev`` directory.
"""
from __future__ import annotations

from unittest.mock import patch

import yaml
from click.testing import CliRunner

from esr.cli.main import cli


def test_create_app_submits_register_adapter_command(monkeypatch, tmp_path):
    """End-to-end wizard flow: prompts → validate → queue submit."""
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    (tmp_path / "default" / "admin_queue" / "pending").mkdir(parents=True)

    # Redirect --target-env dev to tmp_path instead of ~/.esrd-dev.
    import esr.cli.adapter.feishu as feishu_mod
    monkeypatch.setitem(feishu_mod._HOME_MAP, "dev", str(tmp_path))

    with patch("esr.cli.adapter.feishu._validate_creds", return_value=True):
        runner = CliRunner()
        result = runner.invoke(
            cli,
            [
                "adapter",
                "feishu",
                "create-app",
                "--name",
                "ESR 开发助手",
                "--target-env",
                "dev",
                "--no-wait",
            ],
            input="cli_test_app_id\ntest_app_secret\n",
        )
    assert result.exit_code == 0, result.output

    pending = list((tmp_path / "default" / "admin_queue" / "pending").glob("*.yaml"))
    assert len(pending) == 1, result.output
    cmd = yaml.safe_load(pending[0].read_text())
    assert cmd["kind"] == "register_adapter"
    assert cmd["args"]["type"] == "feishu"
    assert cmd["args"]["name"] == "ESR 开发助手"
    assert cmd["args"]["app_id"] == "cli_test_app_id"
    assert cmd["args"]["app_secret"] == "test_app_secret"


def test_create_app_validation_failure_exits_nonzero(monkeypatch, tmp_path):
    """Bad credentials → ``_validate_creds`` returns False → exit 1, no queue write."""
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    (tmp_path / "default" / "admin_queue" / "pending").mkdir(parents=True)

    import esr.cli.adapter.feishu as feishu_mod
    monkeypatch.setitem(feishu_mod._HOME_MAP, "dev", str(tmp_path))

    with patch("esr.cli.adapter.feishu._validate_creds", return_value=False):
        runner = CliRunner()
        result = runner.invoke(
            cli,
            [
                "adapter",
                "feishu",
                "create-app",
                "--name",
                "bad-app",
                "--target-env",
                "dev",
                "--no-wait",
            ],
            input="bad_id\nbad_secret\n",
        )

    assert result.exit_code != 0
    # No pending command should have been written — validation short-circuits.
    pending = list((tmp_path / "default" / "admin_queue" / "pending").glob("*.yaml"))
    assert pending == []
    # Error surfaces on stderr (or combined output) with a specific message.
    combined = result.output + (result.stderr if result.stderr_bytes else "")
    assert "tenant_access_token" in combined or "验证失败" in combined


def test_create_app_prints_prefilled_url_with_scopes_and_events(monkeypatch, tmp_path):
    """The pre-filled URL must include scopes, events, and the backend_oneclick source flag."""
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.delenv("ESR_INSTANCE", raising=False)
    (tmp_path / "default" / "admin_queue" / "pending").mkdir(parents=True)

    import esr.cli.adapter.feishu as feishu_mod
    monkeypatch.setitem(feishu_mod._HOME_MAP, "dev", str(tmp_path))

    with patch("esr.cli.adapter.feishu._validate_creds", return_value=True):
        runner = CliRunner()
        result = runner.invoke(
            cli,
            [
                "adapter",
                "feishu",
                "create-app",
                "--name",
                "demo",
                "--target-env",
                "dev",
                "--no-wait",
            ],
            input="id\nsecret\n",
        )
    assert result.exit_code == 0, result.output
    assert "backend_oneclick" in result.output
    # Scope ``im:message`` appears URL-encoded (``:`` → ``%3A``) in the launcher URL.
    assert "im%3Amessage" in result.output
    # Event ``im.message.receive_v1`` appears verbatim (``.`` is unreserved).
    assert "im.message.receive_v1" in result.output
