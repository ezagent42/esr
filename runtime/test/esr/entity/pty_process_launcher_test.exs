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
  test "os_cmd/1 does not reference the deleted esr-cc.sh" do
    # Build a minimal state struct for PtyProcess.
    state = %{
      start_cmd: nil,
      session_id: "test-sid",
      workspace_name: "test-ws",
      chat_id: "oc_test",
      app_id: "cli_test",
      dir: nil
    }

    cmd = Esr.Entity.PtyProcess.os_cmd(state)
    cmd_str = Enum.join(cmd, " ")

    refute String.contains?(cmd_str, "esr-cc.sh"),
           "os_cmd must not reference deleted esr-cc.sh; got: #{inspect(cmd)}"
  end
end
