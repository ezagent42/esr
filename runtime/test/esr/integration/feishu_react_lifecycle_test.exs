defmodule Esr.Integration.FeishuReactLifecycleTest do
  @moduledoc """
  PR-9 T5 — FeishuChatProxy react/un-react delivery-ack lifecycle.

  Architectural invariant under test: `react` / `un_react` are NOT
  CC-emitted MCP tool actions. They are **per-IM-proxy** concerns.

  Flow exercised:

      ┌──────────────────────────────────────────────────────────────┐
      │ 1. Inbound non-slash text arrives at FeishuChatProxy         │
      │ 2. FCP forwards `{:text, bytes}` to CCProcess                │
      │ 3. FCP emits `{:outbound, %{"kind" => "react", …}}` to       │
      │    feishu_app_proxy neighbor (EYES / 👀)                     │
      │ 4. FCP tracks {message_id ⇒ emoji} in state.pending_reacts   │
      │                                                              │
      │ 5. CC replies with `reply_to_message_id = <inbound id>`      │
      │    → CCProcess.dispatch_action emits `:reply, text, %{…}`    │
      │ 6. FCP.handle_downstream un-reacts that message_id first     │
      │    (outbound envelope kind="un_react"), then forwards the    │
      │    reply text (kind="reply")                                 │
      │ 7. state.pending_reacts no longer carries the msg_id         │
      └──────────────────────────────────────────────────────────────┘

  The test drives the FCP directly (avoiding SessionRouter spawn-order
  constraints and Python handler IPC) — but uses the real
  FeishuAppAdapter peer as the outbound sink so the adapter's own
  `{:outbound, envelope}` broadcast to `adapter:feishu/<app_id>`
  is exercised end-to-end. A real `mock_feishu` round-trip lives in
  the shell scenarios (`tests/e2e/scenarios/01_*.sh`).
  """
  use ExUnit.Case, async: false

  alias Esr.Peers.FeishuAppAdapter
  alias Esr.Peers.FeishuChatProxy

  @moduletag :integration

  setup do
    assert is_pid(Process.whereis(Esr.SessionRegistry))
    assert is_pid(Process.whereis(Esr.AdminSessionProcess))

    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :shutdown) end)
    {:ok, sup: sup}
  end

  test "inbound-ack react then reply un-reacts then forwards reply text", %{sup: sup} do
    app_id = "t5_lifecycle_#{System.unique_integer([:positive])}"

    # Real FeishuAppAdapter peer — broadcasts on `adapter:feishu/<app_id>`.
    {:ok, faa} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuAppAdapter,
         %{app_id: app_id, neighbors: [], proxy_ctx: %{}}}
      )

    # Mock cc_process neighbor — just relays forwarded {:text, _} to the test.
    test_pid = self()
    cc_process = spawn_link(fn -> relay(test_pid, :cc) end)

    # FeishuChatProxy wired to FAA as its feishu_app_proxy neighbor.
    {:ok, fcp} =
      DynamicSupervisor.start_child(
        sup,
        {FeishuChatProxy,
         %{
           session_id: "s_t5",
           chat_id: "oc_t5",
           thread_id: "om_t5",
           neighbors: [cc_process: cc_process, feishu_app_proxy: faa],
           proxy_ctx: %{}
         }}
      )

    # Subscribe to the adapter outbound topic — directives land here in
    # production for the Python adapter_runner to consume.
    topic = "adapter:feishu/#{app_id}"
    :ok = EsrWeb.Endpoint.subscribe(topic)
    on_exit(fn -> EsrWeb.Endpoint.unsubscribe(topic) end)

    inbound_msg_id = "om_inbound_t5_#{System.unique_integer([:positive])}"

    # ────────────────────────────────────────────────
    # Step 1-3: inbound text → FCP → CCProcess + FAA react
    # ────────────────────────────────────────────────
    send(fcp, {:feishu_inbound,
               %{"payload" => %{
                   "text" => "hello from user",
                   "message_id" => inbound_msg_id
                 }}})

    # CCProcess received the forwarded text.
    assert_receive {:relay, :cc, {:text, "hello from user"}}, 1_000

    # FAA broadcast the react on the adapter topic.
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "envelope",
                     payload: %{
                       "kind" => "react",
                       "args" => %{
                         "msg_id" => ^inbound_msg_id,
                         "emoji_type" => "EYES"
                       }
                     }
                   },
                   1_000

    # Step 4: FCP state now tracks the pending react.
    assert %{pending_reacts: %{^inbound_msg_id => "EYES"}} = :sys.get_state(fcp)

    # ────────────────────────────────────────────────
    # Step 5-7: CC reply (with reply_to_message_id) → un_react then reply
    # ────────────────────────────────────────────────
    send(fcp, {:reply, "ack: hello from user",
               %{reply_to_message_id: inbound_msg_id}})

    # Un-react fires FIRST.
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "envelope",
                     payload: %{
                       "kind" => "un_react",
                       "args" => %{
                         "msg_id" => ^inbound_msg_id,
                         "emoji_type" => "EYES"
                       }
                     }
                   },
                   1_000

    # Then the reply text.
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "envelope",
                     payload: %{
                       "kind" => "reply",
                       "args" => %{
                         "chat_id" => "oc_t5",
                         "text" => "ack: hello from user"
                       }
                     }
                   },
                   1_000

    # Step 7: pending_reacts no longer carries the message_id — a retry
    # of the same reply cannot double-un-react.
    %{pending_reacts: pr} = :sys.get_state(fcp)
    refute Map.has_key?(pr, inbound_msg_id)
  end

  # Minimal relay used for the cc_process neighbor — tags messages with a
  # label so the test can distinguish them from FAA broadcasts.
  defp relay(reply_to, label) do
    receive do
      msg ->
        send(reply_to, {:relay, label, msg})
        relay(reply_to, label)
    end
  end
end
