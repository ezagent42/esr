"""PRD 07 F22 — error UX: exit codes, stderr, suggestions."""

from __future__ import annotations

from click.testing import CliRunner

from esr.cli.main import cli


def test_unknown_subcommand_exits_nonzero() -> None:
    runner = CliRunner()
    result = runner.invoke(cli, ["bogus"])
    assert result.exit_code != 0


def test_help_flag_works_on_every_group() -> None:
    runner = CliRunner()
    for group in (["--help"], ["use", "--help"], ["cmd", "--help"], ["adapter", "--help"]):
        result = runner.invoke(cli, group)
        assert result.exit_code == 0, f"{group}: {result.output}"


def test_use_without_context_suggests_command() -> None:
    """PRD 07 F22: errors with obvious fixes include a suggestion."""
    runner = CliRunner()
    # isolated HOME via monkeypatch inside the test itself
    import os

    old_home = os.environ.get("HOME")
    os.environ["HOME"] = "/tmp/definitely-no-esr-context-here"
    os.environ.pop("ESR_CONTEXT", None)
    try:
        result = runner.invoke(cli, ["use"])
        assert result.exit_code != 0
        # Click with err=True mixes stderr into result.output under mix_stderr
        assert "esr use" in result.output
    finally:
        if old_home is not None:
            os.environ["HOME"] = old_home
