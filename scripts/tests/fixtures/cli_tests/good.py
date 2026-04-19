def test_cmd_run_happy(esrd_fixture):
    result = esrd_fixture.run_cli(["cmd", "run", "x"])
    assert result.returncode == 0
