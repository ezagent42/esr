defmodule Esr.Entity.CCProcess.InboundRegressionTest do
  @moduledoc """
  Regression tests for the e2e scenario 01 failure mode (cc didn't
  reply 'ack' within 60s). Per memory rule "every distinct e2e bug
  earns a fast regression test before landing the fix".

  ## What scenario 01 implicitly relies on

  Inbound text → FCP → cc_proxy → cc_process → handler returns
  `send_input` action → cc_process broadcasts a
  `notifications/claude/channel`-shaped envelope on Phoenix topic
  `cli:channel/<sid>`. The stdio bridge (`cc_channel_runner`) joins
  this topic immediately on phx_join, so notifications are never
  lost — MCP readiness is inherent to bridge startup (CC can't issue
  tools/call before MCP `initialized`).

  Pre-stdio-bridge, an HTTP MCP boot bridge could lose notifications
  during the gap before `cc_mcp_ready` flipped, and a PTY-fallback
  branch (PR-24) routed text to PTY stdin in that window. Phase 5.1
  of the stdio-bridge migration deleted both the readiness gate AND
  the fallback — production now has a single broadcast path.
  """
  use ExUnit.Case, async: false

  alias Esr.Entity.CCProcess

  @handler_module "cc_adapter_runner"

  defp relay(parent, tag) do
    receive do
      msg ->
        send(parent, {:relay, tag, msg})
        relay(parent, tag)
    end
  end

  describe "send_input broadcast (production happy path)" do
    test "send_input action broadcasts notification on cli:channel/<sid>" do
      sid = "regression_ready_#{System.unique_integer([:positive])}"
      me = self()
      pty = spawn_link(fn -> relay(me, :pty) end)
      cc_proxy = spawn_link(fn -> relay(me, :cc_proxy) end)

      {:ok, pid} =
        CCProcess.start_link(%{
          session_id: sid,
          handler_module: @handler_module,
          neighbors: [pty_process: pty, cc_proxy: cc_proxy],
          proxy_ctx: %{}
        })

      # Subscribe to the broadcast topic before sending so we don't
      # miss the notification.
      :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cli:channel/" <> sid)

      # Echo handler: send_input mirrors the upstream event text.
      :ok =
        CCProcess.put_handler_override(pid, fn _mod, payload, _timeout ->
          text = get_in(payload, ["event", "args", "text"]) || ""
          {:ok, %{}, [%{"type" => "send_input", "text" => text}]}
        end)

      send(pid, {:text, "please reply with 'ack'"})

      assert_receive {:notification,
                      %{
                        "kind" => "notification",
                        "content" => "please reply with 'ack'"
                      }},
                     500
    end
  end
end
