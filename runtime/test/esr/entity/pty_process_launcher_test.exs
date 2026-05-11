defmodule Esr.Entity.PtyProcessLauncherTest do
  use ExUnit.Case, async: true

  # Phase 8 invariant: PtyProcess must NOT have a launcher_script_path/0
  # function. The esr-cc.sh script was deleted in Phase 8.1; the
  # Elixir-native Launcher (Esr.Plugins.ClaudeCode.Launcher) supersedes it.
  test "launcher_script_path/0 is removed from PtyProcess" do
    refute function_exported?(Esr.Entity.PtyProcess, :launcher_script_path, 0),
           "launcher_script_path/0 must be removed; use Esr.Plugins.ClaudeCode.Launcher instead"
  end

  # default_start_cmd/0 is a private helper that returned the path to
  # esr-cc.sh. After Phase 8, it must either be removed entirely or not
  # reference the deleted script. We test the public surface: os_cmd/1
  # must NOT return a list containing "esr-cc.sh".
  #
  # PR-2 (2026-05-11 spec rev-3): nil :dir no longer falls back to /tmp
  # — os_cmd/1 now raises RuntimeError (prepare_spawn returns
  # :missing_dir). We assert that raise here so this test guards the
  # PR-2 invariant alongside the Phase 8 esr-cc.sh removal.
  test "os_cmd/1 does not reference the deleted esr-cc.sh AND rejects nil :dir" do
    # Build a minimal state struct for PtyProcess with nil :dir.
    state = %{
      start_cmd: nil,
      session_id: "test-sid",
      workspace_name: "test-ws",
      chat_id: "oc_test",
      app_id: "cli_test",
      dir: nil
    }

    # PR-2 invariant: nil :dir surfaces as a clean structural error.
    assert_raise RuntimeError, ~r/prepare_spawn failed.*missing_dir/, fn ->
      Esr.Entity.PtyProcess.os_cmd(state)
    end

    # Phase 8 invariant: on the happy path (dir provided + claude on PATH),
    # os_cmd must NOT reference esr-cc.sh. Skip-on-absence: if `claude`
    # isn't on the test machine PATH we can't reach the argv-build step.
    if System.find_executable("claude") do
      cwd = Path.join(System.tmp_dir!(), "ptp_launcher_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(cwd) end)

      # Per-test ESRD_HOME so the mcp.json write lands in an isolated dir.
      saved_home = System.get_env("ESRD_HOME")
      System.put_env("ESRD_HOME", cwd)
      on_exit(fn ->
        if saved_home,
          do: System.put_env("ESRD_HOME", saved_home),
          else: System.delete_env("ESRD_HOME")
      end)

      good_state = %{state | dir: cwd}
      cmd = Esr.Entity.PtyProcess.os_cmd(good_state)
      cmd_str = Enum.join(cmd, " ")

      refute String.contains?(cmd_str, "esr-cc.sh"),
             "os_cmd must not reference deleted esr-cc.sh; got: #{inspect(cmd)}"
    end
  end
end
