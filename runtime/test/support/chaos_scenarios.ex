defmodule Esr.Test.ChaosScenarios do
  @moduledoc """
  Test DSL for the I1-I5 cross-supervisor invariants (`docs/notes/
  system-invariants.md`).

  Usage:

      defmodule Esr.System.InvariantsTest do
        use Esr.Test.ChaosScenarios

        invariant_test "I1: every inbound produces chat reply within 5s under chaos" do
          ctx = setup_session_with_listener()
          chaos_inject(ctx.sid, [:cc_process, :pty_process], times: 3)
          send_test_inbound(ctx.sid, "hi")
          assert_chat_reply_within(5_000)
        end
      end

  ## Public surface

    * `invariant_test/2` — `test/2` wrapper that prefixes the description
      with `"INVARIANT: "` (makes the assertion category obvious in
      output).
    * `chaos_inject/3` — kill one randomly-selected peer of the given
      role(s) in a session, N times, with brief pauses between kills.
    * `eventually/3` — poll a predicate fn until it returns truthy or
      times out (default 3s).
    * `assert_chat_reply_within/1` — assert_receive shim for
      `{:chat_reply, _}` messages routed through the test process.
    * `setup_session_with_listener/0` — best-effort fixture that starts
      a real `Esr.Session.Router.create_session/1` session with the
      test process registered as the FCP relay. Falls back to a
      minimal sid-only setup when full app boot isn't available (unit
      isolation).
    * `kill_role_in_session/2` — one-shot version of `chaos_inject` for
      a single peer.
    * `send_test_inbound/2` — emit a synthetic `{:feishu_inbound, ...}`
      envelope to a session's FCP pid via the role index.

  Plan: PR-3 Task 3.8. Spec §4.7.
  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false
      import Esr.Test.ChaosScenarios
    end
  end

  @doc """
  Defines an `ExUnit.test/2` whose description is prefixed with
  `"INVARIANT: "`. Use one per cross-system invariant so test output
  surfaces invariant violations as a distinct class.
  """
  defmacro invariant_test(description, do: block) do
    quote do
      test "INVARIANT: " <> unquote(description) do
        unquote(block)
      end
    end
  end

  @doc """
  Defines an `ExUnit.test/2` accepting a context with the
  `"INVARIANT: "` prefix.
  """
  defmacro invariant_test(description, ctx, do: block) do
    quote do
      test "INVARIANT: " <> unquote(description), unquote(ctx) do
        unquote(block)
      end
    end
  end

  @doc """
  Kill one of the given role pids in `sid`, `times` times, with a brief
  pause between kills. `roles` may be a single atom or a list.

  No-op when the role index is empty for `sid` — chaos against an
  already-dead session is a degenerate case the invariants still treat
  as valid.
  """
  @spec chaos_inject(String.t(), atom() | [atom()], keyword()) :: :ok
  def chaos_inject(sid, roles, opts \\ []) do
    times = Keyword.get(opts, :times, 1)
    pause_ms = Keyword.get(opts, :pause_ms, 50)
    roles = List.wrap(roles)

    Enum.each(1..times, fn _ ->
      role = Enum.random(roles)

      case Esr.ActorQuery.list_by_role(sid, role) do
        [pid | _] when is_pid(pid) ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)

        _ ->
          :ok
      end

      Process.sleep(pause_ms)
    end)

    :ok
  end

  @doc """
  Kill the (first) pid registered under `role` in `sid`. One-shot
  variant of `chaos_inject/3`. Returns the killed pid or `:not_found`.
  """
  @spec kill_role_in_session(String.t(), atom()) :: pid() | :not_found
  def kill_role_in_session(sid, role) when is_binary(sid) and is_atom(role) do
    case Esr.ActorQuery.list_by_role(sid, role) do
      [pid | _] when is_pid(pid) ->
        Process.exit(pid, :kill)
        pid

      _ ->
        :not_found
    end
  end

  @doc """
  Send a synthetic `{:feishu_inbound, envelope}` to the FCP pid for
  `sid`, with `text` as the envelope's `args["content"]`. Used by
  invariant tests that need to drive an inbound through the FAA route
  without going through the WebSocket boundary.

  Returns `:ok` when the FCP is reachable, `:not_found` otherwise.
  """
  @spec send_test_inbound(String.t(), String.t()) :: :ok | :not_found
  def send_test_inbound(sid, text) when is_binary(sid) and is_binary(text) do
    envelope = %{
      "payload" => %{
        "event_type" => "msg_received",
        "args" => %{"content" => text}
      }
    }

    case Esr.ActorQuery.fcp_for_session(sid) do
      {:ok, pid} ->
        send(pid, {:feishu_inbound, envelope})
        :ok

      :not_found ->
        :not_found
    end
  end

  @doc """
  Poll `fun.()` until it returns truthy or `timeout_ms` elapses. Calls
  `ExUnit.Assertions.flunk/1` on timeout.

  Use for steady-state assertions that must hold "eventually" under
  chaos — see I2, I3 invariants.
  """
  @spec eventually((-> any()), non_neg_integer(), non_neg_integer()) :: :ok
  def eventually(fun, timeout_ms \\ 3_000, poll_ms \\ 50)
      when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, poll_ms)
  end

  defp do_eventually(fun, deadline, poll_ms) do
    case fun.() do
      truthy when truthy not in [false, nil] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          ExUnit.Assertions.flunk("eventually/3 timed out")
        else
          Process.sleep(poll_ms)
          do_eventually(fun, deadline, poll_ms)
        end
    end
  end

  @doc """
  ExUnit's `assert_receive` for `{:chat_reply, _}` messages. The test
  process must be wired as a chat reply listener — see
  `setup_session_with_listener/0`.

  This macro must be called from a test that has imported
  `ExUnit.Assertions` (true when the test uses `Esr.Test.ChaosScenarios`).
  """
  defmacro assert_chat_reply_within(timeout_ms) do
    quote do
      assert_receive {:chat_reply, _}, unquote(timeout_ms)
    end
  end

  @doc """
  Stub session-with-listener fixture for routing-level invariants.

  Returns `%{sid: sid, chat_id: chat, app_id: app}`.

  Attaches a synthetic sid to the chat-routing slot and injects the
  test process as the FCP in the role index (Index 3 direct insert).
  This is sufficient for routing-level chaos (I1, I2) — the test
  process IS the FCP, so `{:feishu_inbound, _}` arrives on `self()`.

  Full-pipeline invariants (I3 supervisor-DOWN cleanup, I4 agent
  death chat-visible reply) require the real `Router.create_session/1`
  path with a writable workspace + bundled agent_def. Those run in
  the integration suite (futures/todo.md "integration-level I-tests").
  """
  @spec setup_session_with_listener() :: %{
          sid: String.t(),
          chat_id: String.t(),
          app_id: String.t()
        }
  def setup_session_with_listener do
    chat = "oc_chaos_#{System.unique_integer([:positive])}"
    app = "app_chaos_#{System.unique_integer([:positive])}"
    test_pid = self()

    sid = "chaos-stub-sid-#{System.unique_integer([:positive])}"
    :ok = Esr.Session.ChatRouting.Registry.attach_session(chat, app, sid)

    :ets.insert(
      :esr_actor_role_index,
      {{sid, :feishu_chat_proxy}, {test_pid, "chaos-actor-#{:rand.uniform(99_999)}"}}
    )

    %{sid: sid, chat_id: chat, app_id: app}
  end
end
