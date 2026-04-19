import esr.cli.main as main_mod


def test_cmd_run_happy(mocker, esrd_fixture):
    mocker.patch.object(main_mod, "_submit_cmd_run", return_value={"ok": True})
