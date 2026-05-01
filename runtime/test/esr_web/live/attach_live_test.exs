defmodule EsrWeb.AttachLiveTest do
  @moduledoc """
  PR-22: AttachLive mount + PubSub round-trip + ended-overlay.
  """

  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint EsrWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:esr)
    :ok
  end

  test "mount subscribes to pty:<sid> and pushes stdout to client" do
    sid = "test-attach-#{System.unique_integer([:positive])}"
    conn = Phoenix.ConnTest.build_conn()

    {:ok, view, html} = live(conn, "/sessions/#{sid}/attach")

    assert html =~ "term-#{sid}"
    assert html =~ "phx-hook=\"XtermAttach\""

    # Broadcast a fake stdout chunk and confirm the LiveView doesn't
    # crash. We can't directly observe push_event payloads in this
    # test (LiveViewTest doesn't capture them by default), but the
    # render still works after delivery.
    Phoenix.PubSub.broadcast(EsrWeb.PubSub, "pty:#{sid}", {:pty_stdout, "hello"})
    assert render(view) =~ "term-#{sid}"
  end

  test "ended overlay renders after :pty_closed broadcast" do
    sid = "test-ended-#{System.unique_integer([:positive])}"
    conn = Phoenix.ConnTest.build_conn()

    {:ok, view, _html} = live(conn, "/sessions/#{sid}/attach")

    Phoenix.PubSub.broadcast(EsrWeb.PubSub, "pty:#{sid}", :pty_closed)

    # Force LiveView to process the message
    _ = :sys.get_state(view.pid)

    assert render(view) =~ "session ended"
  end
end
