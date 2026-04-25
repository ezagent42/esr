defmodule Esr.Perf.SessionRouterDispatchLatencyTest do
  @moduledoc """
  P5-10 — measure the wall-clock latency of a synthetic inbound event
  traversing the control-plane dispatch from a `FeishuAppAdapter` into
  the owning Session's `feishu_chat_proxy` neighbor.

  Bootstrap adjustments from the plan's Step-3 skeleton:

    * The plan's skeleton sends `{:inbound_event, env}` to
      `Esr.SessionRouter`, but `SessionRouter` is the **control-plane**
      GenServer (create/end session, peer-crash monitor) and does NOT
      handle `:inbound_event` — those messages would hit the Risk-E
      "dropped unexpected info" clause and no relay would ever fire.
      The real dispatcher for `:inbound_event` is `FeishuAppAdapter`
      (see `runtime/lib/esr/peers/feishu_app_adapter.ex:49`), which
      looks up the owning Session via `SessionRegistry` and forwards
      `{:feishu_inbound, envelope}` to its `feishu_chat_proxy` pid.
      That hop — webhook → SessionRegistry lookup → Session peer —
      IS the dispatch path Spec §11 calls out. We measure it directly
      here, mirroring the wiring in
      `runtime/test/esr/integration/n2_sessions_test.exs`.

    * The stub tmux peer is registered as `tmux_process` for parity with
      the plan text, but the observed message shape is
      `{:feishu_inbound, _}` (FCP relay), not `{:tmux_output, _}`. The
      plan's "POSSIBLE ISSUES" note anticipates this.

  Stubs tmux by registering a plain-pid subscriber in place of a real
  tmux-owning peer, so the measurement excludes erlexec / port-dial
  cost; the number we capture is the pure-Elixir dispatch cost through
  the control-plane.

  Tagged `:perf` — excluded from the default `mix test` profile.
  Invoke with `mix test --only perf` to gather numbers.
  """
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuAppAdapter

  @tag :perf
  test "SessionRouter dispatch latency: 1000 iterations, record p50 / p99" do
    # App-level singletons (booted by Esr.Application).
    :ok = Esr.TestSupport.AppSingletons.assert_app_singletons(%{})

    # Agents must be loaded so Session subtree init can resolve the
    # agent_def if any downstream code consults it. Mirrors the setup
    # in `runtime/test/esr/integration/n2_sessions_test.exs`.
    :ok =
      Esr.SessionRegistry.load_agents(
        Path.expand("../fixtures/agents/multi_app.yaml", __DIR__)
      )

    session_id = "perf-p5-10-#{System.unique_integer([:positive])}"
    app_id = "perf_#{System.unique_integer([:positive])}"
    chat_id = "oc_perf_#{System.unique_integer([:positive])}"
    thread_id = "om_perf_#{System.unique_integer([:positive])}"

    test_pid = self()

    # Stub "tmux" / relay: a plain pid that forwards every message back
    # to the test process tagged `:relay`, so we can distinguish the
    # dispatch observation from unrelated noise.
    stub_relay = spawn_link(fn -> relay_loop(test_pid) end)

    {:ok, session_sup} =
      Esr.SessionsSupervisor.start_session(%{
        session_id: session_id,
        agent_name: "cc",
        dir: "/tmp",
        chat_thread_key: %{chat_id: chat_id, thread_id: thread_id},
        metadata: %{principal_id: "ou_perf"}
      })

    assert Process.alive?(session_sup)

    # Register the Session in SessionRegistry with feishu_chat_proxy
    # pointing at the stub relay. FeishuAppAdapter.handle_upstream/2
    # forwards `{:feishu_inbound, envelope}` here on
    # lookup_by_chat_thread hit.
    :ok =
      Esr.SessionRegistry.register_session(
        session_id,
        # PR-A T1: app_id mirrors instance_id so the FAA fallback path
        # (state.instance_id when args["app_id"] absent) hits this row.
        %{chat_id: chat_id, app_id: app_id, thread_id: thread_id},
        %{feishu_chat_proxy: stub_relay, tmux_process: stub_relay}
      )

    # Per-test FeishuAppAdapter under a scoped DynamicSupervisor so we
    # don't leak into app-level AdminSession children.
    {:ok, fab_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    {:ok, _fab} =
      DynamicSupervisor.start_child(
        fab_sup,
        {FeishuAppAdapter, %{instance_id: app_id, neighbors: [], proxy_ctx: %{}}}
      )

    {:ok, fab_pid} =
      Esr.AdminSessionProcess.admin_peer(
        String.to_atom("feishu_app_adapter_#{app_id}")
      )

    on_exit(fn ->
      Esr.SessionRegistry.unregister_session(session_id)

      if Process.alive?(session_sup) do
        Esr.SessionsSupervisor.stop_session(session_sup)
      end

      if Process.alive?(fab_sup), do: Process.exit(fab_sup, :shutdown)
    end)

    env = %{
      "payload" => %{
        "chat_id" => chat_id,
        "thread_id" => thread_id,
        "text" => "perf probe"
      }
    }

    # Warm-up: first iteration tends to include lazy-init costs
    # (registry ETS, message-queue warmup). Discard it.
    send(fab_pid, {:inbound_event, env})
    assert_receive {:relay, {:feishu_inbound, _}}, 1_000

    n = 1000

    samples =
      for _ <- 1..n do
        t0 = System.monotonic_time(:microsecond)
        send(fab_pid, {:inbound_event, env})
        assert_receive {:relay, {:feishu_inbound, _}}, 500
        System.monotonic_time(:microsecond) - t0
      end

    sorted = Enum.sort(samples)
    p50 = Enum.at(sorted, div(n, 2))
    p99 = Enum.at(sorted, div(n * 99, 100))

    IO.puts(
      "perf: SessionRouter dispatch latency (n=#{n}) p50=#{p50}µs p99=#{p99}µs"
    )

    # Only regression-guard the p99; p50 is purely informational.
    # Threshold is generous because this is a synthetic stub — the
    # real goal is to capture a stable number for PR-6 to compare
    # against.
    assert p99 < 10_000, "p99 dispatch latency over 10ms is suspicious"

    # Persist the numbers for PR-6 to pick up without re-running the
    # smoke; a plain tmpfile is sufficient.
    File.write!(
      System.tmp_dir!() <> "/esr-pr5-perf-baseline.tsv",
      "p50_us\tp99_us\n#{p50}\t#{p99}\n"
    )
  end

  # Tiny relay: forwards every message to the test process tagged
  # `:relay` so assert_receive can discriminate our dispatch
  # observations from unrelated mailbox traffic.
  defp relay_loop(dest) do
    receive do
      msg ->
        send(dest, {:relay, msg})
        relay_loop(dest)
    end
  end
end
