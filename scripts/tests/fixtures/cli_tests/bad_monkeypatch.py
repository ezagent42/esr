def test_cmd_run_happy(monkeypatch, esrd_fixture):
    monkeypatch.setattr("esr.cli.main._submit_cmd_run", lambda *a: {"ok": True})
