defmodule Esr.Admin.Commands.CrossAppTest do
  @moduledoc """
  Test-harness command for E2E scenario 04 (PR-A): synthesizes a
  `tool_invoke` directly into a session's `FeishuChatProxy` peer,
  bypassing the claude TUI.

  Why this exists: scenario 04 §5.4 (forbidden) and §5.5 (non-member)
  exercise FCP's cross-app `dispatch_cross_app_reply` auth gate. In
  the prompt-driven E2E path, real claude refuses requests asking for
  cross-app forwards as a prompt-injection / lateral-movement signal,
  even with system-test framing. The auth gate then never fires
  because no `tool_invoke` reaches the runtime. This command is the
  deterministic injection path: it sends the same arity-6
  `{:tool_invoke, req_id, "reply", args, channel_pid, principal_id}`
  shape that `EsrWeb.ChannelChannel.handle_in("envelope", …)`
  forwards to FCP for an MCP-driven tool call, and synchronously
  receives the `{:push_envelope, %{"req_id" => …, "ok" => …}}`
  response that FCP emits via `reply_tool_result/5`.

  This is **not** a production code path — it's invoked only from
  e2e scenarios. The command is gated behind admin dispatch like all
  other admin commands; if someone uses it to inject tool_invokes in
  production, the same auth gates that would protect a legitimate
  cross-app reply still apply (FCP's `Capabilities.has?/2` check is
  the load-bearing safeguard).

  Args:
    * `session_id` — the target session whose FCP receives the call
    * `chat_id` — the cross-app chat (passed to FCP as args["chat_id"])
    * `app_id` — the cross-app app_id (passed to FCP as args["app_id"])
    * `text` — the reply text
    * `principal_id` — the principal whose caps FCP gates on
    * `req_id` (optional) — defaults to a fresh UUID; lets the test
      correlate result with request

  Result shape mirrors what would land on the cli:channel WebSocket:
    * `{:ok, %{"req_id" => …, "ok" => true, "data" => …}}` on success
    * `{:ok, %{"req_id" => …, "ok" => false, "error" => %{"type" => …}}}`
      on FCP-side deny (forbidden / unknown_chat_in_app / unknown_app)
    * `{:error, %{"type" => "no_session_peer"}}` if the FCP isn't
      registered in `Esr.PeerRegistry`
    * `{:error, %{"type" => "timeout"}}` if FCP doesn't reply in 5s
  """

  @type result :: {:ok, map()} | {:error, map()}

  @reply_timeout_ms 5_000

  @spec execute(map()) :: result()
  def execute(%{"args" => args}) when is_map(args) do
    with {:ok, session_id} <- fetch_arg(args, "session_id"),
         {:ok, chat_id} <- fetch_arg(args, "chat_id"),
         {:ok, app_id} <- fetch_arg(args, "app_id"),
         {:ok, text} <- fetch_arg(args, "text"),
         {:ok, principal_id} <- fetch_arg(args, "principal_id") do
      req_id = Map.get(args, "req_id") || generate_req_id()
      send_tool_invoke(session_id, chat_id, app_id, text, principal_id, req_id)
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "cross_app_test requires args.{session_id, chat_id, app_id, text, principal_id}"
     }}
  end

  defp fetch_arg(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, %{"type" => "invalid_args", "missing" => key}}
    end
  end

  defp generate_req_id do
    "cat-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp send_tool_invoke(session_id, chat_id, app_id, text, principal_id, req_id) do
    peer_name = "thread:" <> session_id

    case Registry.lookup(Esr.PeerRegistry, peer_name) do
      [{peer_pid, _}] when is_pid(peer_pid) ->
        tool_args = %{
          "chat_id" => chat_id,
          "app_id" => app_id,
          "text" => text
        }

        # Pass `self()` as channel_pid; FCP will send
        # `{:push_envelope, %{"req_id" => req_id, ...}}` back.
        send(peer_pid, {:tool_invoke, req_id, "reply", tool_args, self(), principal_id})

        receive do
          {:push_envelope, %{"req_id" => ^req_id} = envelope} ->
            {:ok, envelope}
        after
          @reply_timeout_ms ->
            {:error,
             %{
               "type" => "timeout",
               "req_id" => req_id,
               "message" => "FCP did not reply within #{@reply_timeout_ms}ms"
             }}
        end

      [] ->
        {:error,
         %{
           "type" => "no_session_peer",
           "session_id" => session_id,
           "message" => "no thread:" <> session_id <> " peer in PeerRegistry"
         }}
    end
  end
end
