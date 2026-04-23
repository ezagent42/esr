defmodule Esr.TestSupport.TmuxIsolation do
  @moduledoc """
  Shared ExUnit `setup` helper: gives each test a unique tmux socket
  path + a registered `on_exit` that `kill-server`s and removes the
  file. Prevents integration-test tmux sessions from leaking into the
  user's default socket (`/tmp/tmux-<uid>/default`).

  Use in integration tests that call `Esr.SessionRouter.create_session/1`
  or spawn `Esr.Peers.TmuxProcess` directly:

      setup :isolated_tmux_socket

      test "my test", %{tmux_socket: sock} do
        {:ok, sid} = SessionRouter.create_session(%{
          agent: "cc", dir: "/tmp",
          chat_id: ..., thread_id: ..., principal_id: ...,
          tmux_socket: sock   # ← propagates to TmuxProcess via spawn_args
        })
      end

  `Esr.SessionRouter.spawn_args/2` forwards `:tmux_socket` to
  `Esr.Peers.TmuxProcess`; its `on_terminate/1` runs `tmux -S <sock>
  kill-server` + `File.rm` on the socket file.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @spec isolated_tmux_socket(map()) :: {:ok, keyword()}
  def isolated_tmux_socket(_ctx) do
    sock = Path.join(System.tmp_dir!(), "esr-tmux-#{:erlang.unique_integer([:positive])}.sock")

    on_exit(fn ->
      # Defensive cleanup — TmuxProcess.on_terminate also does this,
      # but if the test crashes mid-setup or the peer chain doesn't
      # spawn, this catches it.
      System.cmd("tmux", ["-S", sock, "kill-server"], stderr_to_stdout: true)
      File.rm(sock)
    end)

    {:ok, tmux_socket: sock}
  end
end
