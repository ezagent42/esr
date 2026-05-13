defmodule Esr.Entity.CCProcess.MultiSessionTest do
  @moduledoc """
  Phase 7 (2026-05-10) **invariant gate** for the multi-session-per-
  instance architecture.

  Per `feedback_completion_requires_invariant_test.md`: the architectural
  goal of Phase 7 is "one CCProcess instance can be attached to N
  sessions, and each inbound's reply lands on the right session's
  cli:channel/<sid> topic". This test pins that invariant — without it
  a future refactor could regress the topic-routing without ExUnit
  firing, exactly the silent-failure mode that motivated the rule.

  ## What's pinned

  1. send_input action: when `meta.current_session_id` is set, the
     broadcast goes out on `cli:channel/<current_session_id>` — NOT on
     `cli:channel/<state.session_id>`.
  2. reply action (covered indirectly): same routing key.
  3. Default behavior (no current_session_id in meta) preserves the
     legacy single-session topic so unit-test paths don't regress.

  See also:
    * `cc_process_test.exs` — base contract
    * `cc_process_inbound_regression_test.exs` — single-session broadcast path
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.CCProcess

  @handler_module "cc_adapter_runner"

  setup do
    # The broadcast topic is keyed by session_id, so isolated unique
    # ids are sufficient for parallel tests.
    sid_a = "phase7_sessA_#{System.unique_integer([:positive])}"
    sid_b = "phase7_sessB_#{System.unique_integer([:positive])}"
    {:ok, sid_a: sid_a, sid_b: sid_b}
  end

  defp boot_cc_process(originating_sid) do
    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: originating_sid,
        handler_module: @handler_module,
        proxy_ctx: %{}
      })

    # Echo handler: send_input mirrors the upstream event text.
    :ok =
      CCProcess.put_handler_override(pid, fn _mod, payload, _timeout ->
        text = get_in(payload, ["event", "args", "text"]) || ""
        {:ok, %{}, [%{"type" => "send_input", "text" => text}]}
      end)

    pid
  end

  describe "Phase 7 invariant: reply routing follows current_session_id" do
    test "two inbounds to the same CCProcess pid (different sessions) → " <>
           "two distinct broadcasts on the right topics",
         %{sid_a: sid_a, sid_b: sid_b} do
      pid = boot_cc_process(sid_a)

      # Subscribe to BOTH topics before either inbound fires.
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cli:channel/" <> sid_a)
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cli:channel/" <> sid_b)

      # Inbound 1: from session A's chat.
      send(
        pid,
        {:text, "hello from A",
         %{
           message_id: "om_A1",
           sender_id: "ou_alice",
           chat_id: "oc_chatA",
           app_id: "feishu_DEV",
           current_session_id: sid_a
         }}
      )

      # Inbound 2: from session B's chat — same CCProcess pid.
      send(
        pid,
        {:text, "hello from B",
         %{
           message_id: "om_B1",
           sender_id: "ou_bob",
           chat_id: "oc_chatB",
           app_id: "feishu_DEV",
           current_session_id: sid_b
         }}
      )

      # The "from A" content must broadcast on cli:channel/<sid_a> only.
      assert_receive {:notification,
                      %{
                        "kind" => "notification",
                        "content" => "hello from A",
                        "chat_id" => "oc_chatA"
                      }},
                     1000

      # The "from B" content must broadcast on cli:channel/<sid_b> only.
      assert_receive {:notification,
                      %{
                        "kind" => "notification",
                        "content" => "hello from B",
                        "chat_id" => "oc_chatB"
                      }},
                     1000

      # Cross-talk pin: no further broadcasts should arrive.
      refute_receive {:notification, _}, 200
    end

    test "without current_session_id in meta, broadcast falls back to state.session_id (back-compat)",
         %{sid_a: sid_a, sid_b: sid_b} do
      pid = boot_cc_process(sid_a)

      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cli:channel/" <> sid_a)
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cli:channel/" <> sid_b)

      # 3-tuple but no current_session_id field — like a legacy/unit-test caller.
      send(
        pid,
        {:text, "no_sid_meta",
         %{
           message_id: "om_legacy",
           sender_id: "ou_alice",
           chat_id: "oc_legacy",
           app_id: "feishu_DEV"
         }}
      )

      # Falls back to state.session_id == sid_a.
      assert_receive {:notification, %{"content" => "no_sid_meta"}}, 1000

      # No broadcast on sid_b's topic — fallback shouldn't accidentally
      # leak across sessions.
      refute_receive {:notification, _}, 200
    end
  end
end
