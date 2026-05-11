defmodule Esr.Plugins.Feishu.SubmitSlashHandlerTest do
  @moduledoc """
  PR-4 (2026-05-11 default-agent + agent-driven-flow plan §5.2):
  unit tests for the `submit_slash` MCP tool dispatch branch in
  `Esr.Plugins.Feishu.FeishuChatProxy.dispatch_tool_invoke/5`.

  Exercises the four observable outcomes:

    1. happy path  → SlashHandler dispatches `/help`, RawCollector
       forwards the structured result, FCP pushes
       `{:push_envelope, %{"kind" => "tool_result", "ok" => true,
                          "data" => %{"text" => ...}}}` on the channel_pid.
    2. invalid args (no `command` key, wrong type) → `tool_result` with
       `"ok" => false`, error `"type" => "invalid_args"`.
    3. session_not_found → `tool_result` with `"ok" => false`,
       error `"kind" => "session_not_found"`.
    4. no_attached_chat → `tool_result` with `"ok" => false`,
       error `"kind" => "no_attached_chat"`.

  Tests run with `async: false` so the in-memory session registry
  insertions don't race with other tests that scan it.
  """

  use ExUnit.Case, async: false

  alias Esr.Plugins.Feishu.FeishuChatProxy
  alias Esr.Resource.Session.Struct, as: SessionStruct

  @uuid_table :esr_resource_sessions_by_uuid

  setup do
    # Same prereqs as feishu_chat_proxy_test.exs.
    assert is_pid(Process.whereis(Esr.Session.ChatRouting.Registry))
    assert is_pid(Process.whereis(Esr.Session.Admin.Process))

    # Session.Registry runs at boot; ETS table must exist.
    assert :ets.info(@uuid_table) != :undefined,
           "Esr.Resource.Session.Registry ETS table must be up at test boot"

    :ok
  end

  describe "submit_slash dispatch (PR-4 §5.2)" do
    test "valid /help dispatches via SlashHandler + RawCollector and pushes tool_result on channel_pid" do
      sid = "submit_slash_" <> uniq()
      seed_session_with_chat(sid, "oc_submit", "cli_submit", "ou_principal")

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_submit",
          app_id: "cli_submit",
          thread_id: "om_submit",
          principal_id: "ou_principal",
          proxy_ctx: %{}
        })

      send(
        peer,
        {:tool_invoke, "req-help", "submit_slash",
         %{"command" => "/help"}, self(), "ou_principal"}
      )

      # SlashHandler.dispatch goes through the real admin process; allow
      # generous timeout in case the slash route table is warming up.
      assert_receive {:push_envelope,
                      %{
                        "kind" => "tool_result",
                        "req_id" => "req-help",
                        "ok" => true,
                        "data" => data
                      }},
                     10_000

      # /help returns %{"text" => "..."} per Esr.Commands.Help.execute/1.
      assert is_map(data)
      assert is_binary(data["text"])

      cleanup_session(sid)
    end

    test "missing/invalid args returns ok=false, error.type=invalid_args" do
      sid = "submit_slash_bad_args_" <> uniq()

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_x",
          app_id: "cli_x",
          thread_id: "om_x",
          principal_id: "ou_x",
          proxy_ctx: %{}
        })

      send(
        peer,
        {:tool_invoke, "req-bad", "submit_slash",
         %{"not_command" => "/help"}, self(), "ou_x"}
      )

      assert_receive {:push_envelope,
                      %{
                        "kind" => "tool_result",
                        "req_id" => "req-bad",
                        "ok" => false,
                        "error" => %{"type" => "invalid_args"}
                      }},
                     1_000
    end

    test "unknown session returns ok=false, error.kind=session_not_found" do
      # session_id that's NOT registered in the ETS table.
      sid = "submit_slash_missing_" <> uniq()

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_m",
          app_id: "cli_m",
          thread_id: "om_m",
          principal_id: "ou_m",
          proxy_ctx: %{}
        })

      send(
        peer,
        {:tool_invoke, "req-missing", "submit_slash",
         %{"command" => "/help"}, self(), "ou_m"}
      )

      assert_receive {:push_envelope,
                      %{
                        "kind" => "tool_result",
                        "req_id" => "req-missing",
                        "ok" => false,
                        "error" => %{"kind" => "session_not_found"}
                      }},
                     2_000
    end

    test "session with empty attached_chats returns ok=false, error.kind=no_attached_chat" do
      sid = "submit_slash_no_chat_" <> uniq()
      seed_session_no_chats(sid, "ou_no_chat")

      {:ok, peer} =
        GenServer.start_link(FeishuChatProxy, %{
          session_id: sid,
          chat_id: "oc_nc",
          app_id: "cli_nc",
          thread_id: "om_nc",
          principal_id: "ou_no_chat",
          proxy_ctx: %{}
        })

      send(
        peer,
        {:tool_invoke, "req-no-chat", "submit_slash",
         %{"command" => "/help"}, self(), "ou_no_chat"}
      )

      assert_receive {:push_envelope,
                      %{
                        "kind" => "tool_result",
                        "req_id" => "req-no-chat",
                        "ok" => false,
                        "error" => %{"kind" => "no_attached_chat"}
                      }},
                     2_000

      cleanup_session(sid)
    end
  end

  # ---- helpers --------------------------------------------------------

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))

  defp seed_session_with_chat(sid, chat_id, app_id, principal_id) do
    session = %SessionStruct{
      id: sid,
      name: "test-" <> sid,
      owner_user: principal_id,
      workspace_id: nil,
      agent_ids: [],
      primary_agent: nil,
      attached_chats: [
        %{
          chat_id: chat_id,
          app_id: app_id,
          attached_by: principal_id,
          attached_at: "2026-05-11T12:00:00Z"
        }
      ],
      created_at: "2026-05-11T12:00:00Z",
      transient: true
    }

    :ets.insert(@uuid_table, {sid, session})
  end

  defp seed_session_no_chats(sid, principal_id) do
    session = %SessionStruct{
      id: sid,
      name: "test-" <> sid,
      owner_user: principal_id,
      workspace_id: nil,
      agent_ids: [],
      primary_agent: nil,
      attached_chats: [],
      created_at: "2026-05-11T12:00:00Z",
      transient: true
    }

    :ets.insert(@uuid_table, {sid, session})
  end

  defp cleanup_session(sid) do
    :ets.delete(@uuid_table, sid)
  end
end
