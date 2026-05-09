defmodule EsrWeb.PtySocketTokenTest do
  @moduledoc """
  PR added 2026-05-09: PtySocket auth requires a Phoenix.Token signed
  token with 10-min TTL (was: any non-empty ?sid= accepted).

  Closes the multi-operator attach-spoof gap deferred from rev-3
  grammar work — without a signed token, anyone who learns the
  actor_id (clipboard leak, screenshot, log spillover) could attach
  to a live PTY. Token is signed under salt "pty_attach" and verified
  with max_age: 600 on every connect attempt.
  """

  use EsrWeb.ConnCase, async: false

  alias EsrWeb.PtySocket

  test "connect/1 with valid token returns {:ok, %{sid: actor_id}}" do
    actor_id = "actor_test_123"
    token = Phoenix.Token.sign(EsrWeb.Endpoint, "pty_attach", actor_id)

    assert {:ok, %{sid: ^actor_id}} = PtySocket.connect(%{params: %{"token" => token}})
  end

  test "connect/1 with tampered token returns :error" do
    actor_id = "actor_test_123"
    token = Phoenix.Token.sign(EsrWeb.Endpoint, "pty_attach", actor_id)
    tampered = String.replace(token, ~r/.$/, "x")

    assert :error = PtySocket.connect(%{params: %{"token" => tampered}})
  end

  test "connect/1 with token signed under different salt returns :error" do
    actor_id = "actor_test_123"
    token = Phoenix.Token.sign(EsrWeb.Endpoint, "wrong_salt", actor_id)

    assert :error = PtySocket.connect(%{params: %{"token" => token}})
  end

  test "connect/1 with expired token returns :error" do
    actor_id = "actor_test_123"
    # `signed_at` is in SECONDS per Phoenix.Token docs (the comment says
    # milliseconds for the default-case current-time, but the option
    # itself takes seconds). 11 minutes ago = past the 600-second
    # max_age verification window.
    eleven_min_ago = System.system_time(:second) - 11 * 60

    token =
      Phoenix.Token.sign(EsrWeb.Endpoint, "pty_attach", actor_id, signed_at: eleven_min_ago)

    assert :error = PtySocket.connect(%{params: %{"token" => token}})
  end

  test "connect/1 with no token param returns :error" do
    assert :error = PtySocket.connect(%{params: %{}})
  end

  test "connect/1 with empty token returns :error" do
    assert :error = PtySocket.connect(%{params: %{"token" => ""}})
  end
end
