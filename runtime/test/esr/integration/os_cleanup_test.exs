defmodule Esr.Integration.OsCleanupTest do
  @moduledoc """
  P3-12 — "nightly gate" OS cleanup regression per spec §10.5.

  Asserts that after `kill -9 <beam_pid>` on the ESRD runtime
  process, no child OS processes owned by that esrd instance
  remain alive after a 10 s grace window. Application-level
  `on_terminate` callbacks DO NOT run under SIGKILL, so this gate
  exercises the child's own EOF-detection-and-self-die mechanism
  (children that lose their stdin/stdout close out).

  ## Test infrastructure status (drift from expansion doc P3-12.2)

  The expansion sketch assumed a ready-to-use subprocess-esrd
  launcher + WS-client helper pair. The repo has
  `scripts/esrd.sh start/stop` (launches via `mix phx.server` on
  a port it reserves and writes to `$ESRD_HOME/<instance>/esrd.pid`
  + `esrd.port`), which would cover the BEAM-process half. What's
  missing for a full implementation:

    * A test-side WS client that can:
      - subscribe to `adapter:feishu/<app_id>` on the subprocess esrd,
      - push an `{:inbound_event, envelope}` whose `(chat_id,
        thread_id)` triggers `SessionRouter` auto-spawn,
      - wait for the resulting `pty_process` to be live.

    * A reliable way to enumerate the child OS processes OWNED BY
      the target esrd instance (vs ones owned by the outer test
      runner, vs sibling CI jobs, vs the dev's own shell). A
      namespacing convention is needed for this test to refuse
      false positives.

  Both are tractable follow-ups, but the combined surface is
  wider than P3-12's charter ("OS cleanup regression task"). The
  spec explicitly allows this fallback:

      > If the mix task infrastructure is too invasive, write the
      > test as a regular :integration-tagged test that can be
      > invoked via `mix test --only os_cleanup` (separate tag)

  and the expansion itself provides the scaffold below verbatim
  with dummy helpers + "mark @tag :skip with a reason".

  ## What IS landed by P3-12

    1. Mix alias `test.e2e.os_cleanup` in `runtime/mix.exs` — maps
       to `test --only os_cleanup`. The tag is wired into the test
       runner with `exclude: [:integration, :os_cleanup]` in
       `test/test_helper.exs` so a plain `mix test` skips it and
       only the explicit alias (or `mix test --only os_cleanup`)
       picks it up.
    2. This scaffold test, registered under the `:os_cleanup` tag,
       marked `@tag :skip` with a reason so CI / nightly runs see
       the tag exists but don't report a spurious green.

  Follow-up work to flesh out the helpers is tracked in the PR
  body. When the subprocess-esrd WS helpers land, remove the
  `@tag :skip` and fill in the `start_esrd_subprocess/1` +
  `create_session_via_ws/2` + `count_esr_pty_sessions/1` +
  `read_beam_os_pid/1` + `kill_9/1` helpers.

  See spec §10.5 (per-PR OS cleanup gate); expansion P3-12.
  """
  use ExUnit.Case, async: false
  @moduletag :os_cleanup

  @tag timeout: 30_000
  @tag :skip
  test "kill -9 of esrd → all child OS processes die within 10s" do
    # This test must NOT run under the standard mix test (it kills
    # a subprocess BEAM, but we want to avoid any accidental signal
    # hitting the test runner's own BEAM). Invoked via
    # `mix test.e2e.os_cleanup` (alias in mix.exs) which maps to
    # `test --only os_cleanup`. The `@tag :skip` above keeps this
    # from reporting a spurious green until the subprocess-esrd
    # helpers below are implemented.
    unique = "oscleanup_#{System.unique_integer([:positive])}"
    port = start_esrd_subprocess(unique)

    # Create one session via WS/CLI → one child OS process
    create_session_via_ws(port, unique)
    Process.sleep(500)

    pre = count_esr_pty_sessions(unique)
    assert pre >= 1

    beam_pid = read_beam_os_pid(unique)
    :ok = kill_9(beam_pid)

    # Wait up to 10s for the child to die. App-level on_terminate
    # won't run on SIGKILL; must rely on the child's own EOF detection
    # (it loses its pipe endpoints when the BEAM dies).
    Process.sleep(10_000)
    post = count_esr_pty_sessions(unique)
    assert post == 0, "found #{post} orphan child processes after kill -9"
  end

  # ------------------------------------------------------------------
  # Helpers — scaffolded. These stubs keep the test compilable but
  # the `@tag :skip` above ensures they never execute until filled in.
  # When replacing them:
  #
  #   * start_esrd_subprocess/1 — shell out to `scripts/esrd.sh start
  #     --instance=<unique>`; read port from $ESRD_HOME/<unique>/esrd.port.
  #     Wait for port to accept WS connections.
  #
  #   * create_session_via_ws/2 — connect to
  #     `ws://127.0.0.1:<port>/adapter/socket/websocket`, join the
  #     `adapter:feishu/<app_id>` topic, push an `envelope` with a
  #     fresh (chat_id, thread_id). SessionRouter auto-spawns the
  #     session.
  #
  #   * count_esr_pty_sessions/1 — enumerate child OS processes
  #     owned by this esrd instance and return a count. Needs an
  #     instance-scoped naming convention so the count refuses
  #     false positives across CI jobs / dev shells.
  #
  #   * read_beam_os_pid/1 — `File.read!($ESRD_HOME/<unique>/esrd.pid)`
  #     |> String.trim |> String.to_integer.
  #
  #   * kill_9/1 — `System.cmd("kill", ["-9", "#{pid}"])`.
  #
  # See scripts/esrd.sh for the subprocess launcher contract.
  # ------------------------------------------------------------------

  defp start_esrd_subprocess(_), do: 9999
  defp create_session_via_ws(_port, _unique), do: :ok
  defp count_esr_pty_sessions(_unique), do: 0
  defp read_beam_os_pid(_unique), do: 0
  defp kill_9(_), do: :ok
end
