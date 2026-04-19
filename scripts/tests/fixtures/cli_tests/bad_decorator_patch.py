from unittest.mock import patch


@patch("esr.cli.main._submit_cmd_run")
def test_cmd_run_happy(_mocked, esrd_fixture):
    pass
