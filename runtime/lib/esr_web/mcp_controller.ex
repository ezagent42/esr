defmodule EsrWeb.McpController do
  @moduledoc """
  HTTP MCP transport for esrd-hosted MCP server. Replaces the
  previous Python `adapters/cc_mcp/` stdio bridge per PR-3.5.

  Two endpoints, both at `/mcp/:session_id`:

  - **POST `/`** — JSON-RPC 2.0 requests. Methods handled:
    - `initialize` → returns server capabilities + protocol version
    - `tools/list` → returns the cc plugin's tool schemas
    - `tools/call` → translates to the existing
      `{:tool_invoke, req_id, tool, args, channel_pid, principal_id}`
      peer message; awaits `{:push_envelope, %{kind: "tool_result"}}`
      reply; returns the JSON-RPC response.

  - **GET `/`** with `Accept: text/event-stream` — opens an SSE
    stream that subscribes the connection process to the per-session
    PubSub topic `cli:channel/<session_id>`. `:notification`
    broadcasts get forwarded as
    `event: notifications/claude/channel\\ndata: <json>\\n\\n`
    SSE frames — the same shape Claude Code listens for under the
    `claude/channel` experimental capability.

  Failure modes (let-it-crash; no try/rescue at the boundary):

  - Unknown session_id (no `thread:<sid>` peer): 404 + JSON-RPC
    error envelope.
  - Tool result timeout (peer never replies): 504 + JSON-RPC error.
  - Malformed JSON body: 400; Bandit's per-request crash isolation
    recovers cleanly.
  - PubSub broadcast on a topic with no subscriber: dropped (matches
    pre-PR-3.5 cc_mcp behaviour; buffer-and-flush is in
    `Esr.Plugins.Feishu.FeishuChatProxy` for the inbound side).

  Per memory rule `feedback_let_it_crash_no_workarounds`: no
  rescue/warn-degrade paths.
  """

  use EsrWeb, :controller
  require Logger

  alias Esr.Plugins.ClaudeCode.Mcp.Tools

  @protocol_version "2025-06-18"
  @server_name "esr-channel"
  @server_version "0.3.0"
  @tool_call_timeout_ms 30_000

  # ------------------------------------------------------------------
  # POST /mcp/:session_id — JSON-RPC requests
  # ------------------------------------------------------------------

  def handle_request(conn, params) do
    session_id = Map.fetch!(params, "session_id")
    # Phoenix endpoint already parsed the JSON body via Plug.Parsers;
    # read it from `body_params` (raw `read_body/1` returns empty by
    # this point because the parser consumed the stream).
    case conn.body_params do
      %{"jsonrpc" => "2.0", "method" => method, "id" => req_id} = req ->
        result = dispatch(method, req["params"] || %{}, session_id)
        send_jsonrpc(conn, req_id, result)

      %{"jsonrpc" => "2.0", "method" => method} = req ->
        # Notification (no id) — dispatch but don't return a response.
        _ = dispatch(method, req["params"] || %{}, session_id)
        send_resp(conn, 204, "")

      _ ->
        send_jsonrpc_error(conn, nil, -32_700, "Parse error")
    end
  end

  # ------------------------------------------------------------------
  # GET /mcp/:session_id — SSE stream for server→client notifications
  # ------------------------------------------------------------------

  def handle_sse(conn, %{"session_id" => session_id}) do
    Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cli:channel/" <> session_id)

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> sse_loop()
  end

  defp sse_loop(conn) do
    receive do
      {:notification, payload} when is_map(payload) ->
        notification_method = "notifications/claude/channel"
        params = build_notification_params(payload)
        frame = encode_sse(notification_method, params)

        case chunk(conn, frame) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _reason} -> conn
        end

      {:push_envelope, %{"kind" => "session_killed"} = env} ->
        # Mirror the cc_mcp `session_killed` semantic: the session is
        # gone, close the SSE stream so claude's MCP client cleans up.
        Logger.info("mcp_controller: session_killed sid=#{inspect(env["session_id"])}")
        conn

      _other ->
        sse_loop(conn)
    after
      30_000 ->
        # Keep-alive: send an SSE comment frame every 30s so proxies
        # don't drop the idle connection.
        case chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _reason} -> conn
        end
    end
  end

  # ------------------------------------------------------------------
  # JSON-RPC method dispatch
  # ------------------------------------------------------------------

  defp dispatch("initialize", _params, _session_id) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "serverInfo" => %{"name" => @server_name, "version" => @server_version},
       "capabilities" => %{
         "tools" => %{},
         "experimental" => %{"claude/channel" => %{}}
       },
       "instructions" =>
         "Messages from users arrive as <channel source=\"feishu\" " <>
           "chat_id=\"...\" message_id=\"...\" user=\"...\"> tags. " <>
           "Reply with the `reply` MCP tool, passing the chat_id from the tag. " <>
           "For file output, use the `send_file` tool with the same chat_id."
     }}
  end

  defp dispatch("tools/list", _params, _session_id) do
    role = System.get_env("ESR_ROLE", "dev")
    {:ok, %{"tools" => Tools.list(role)}}
  end

  defp dispatch("tools/call", %{"name" => tool, "arguments" => args}, session_id)
       when is_binary(tool) and is_map(args) do
    invoke_tool_via_peer(session_id, tool, args)
  end

  defp dispatch("notifications/initialized", _params, _session_id), do: {:ok, %{}}
  defp dispatch("notifications/cancelled", _params, _session_id), do: {:ok, %{}}

  defp dispatch(method, _params, _session_id) do
    {:error, {-32_601, "Method not found: #{method}"}}
  end

  # ------------------------------------------------------------------
  # Tool dispatch — translates to the existing peer protocol
  # ------------------------------------------------------------------

  defp invoke_tool_via_peer(session_id, tool, args) do
    peer_name = "thread:" <> session_id

    case Registry.lookup(Esr.Entity.Registry, peer_name) do
      [{peer_pid, _}] ->
        req_id = ulid()

        principal_id =
          System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID") || "ou_unknown"

        send(peer_pid, {:tool_invoke, req_id, tool, args, self(), principal_id})

        receive do
          {:push_envelope, %{"req_id" => ^req_id} = envelope} ->
            tool_result_to_jsonrpc(envelope)
        after
          @tool_call_timeout_ms ->
            {:error,
             {-32_000,
              "tool_result timeout after #{div(@tool_call_timeout_ms, 1000)}s for tool=#{tool}"}}
        end

      [] ->
        {:error,
         {-32_001, "no thread peer for session #{session_id} (tool=#{tool})"}}
    end
  end

  # The peer's `:push_envelope` payload uses ESR's tool_result shape;
  # the MCP `tools/call` response wants `{content: [{type: "text",
  # text: ...}]}`. Translate.
  defp tool_result_to_jsonrpc(%{"ok" => true, "data" => data}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(data)}]}}
  end

  defp tool_result_to_jsonrpc(%{"ok" => false, "error" => error}) do
    {:ok,
     %{
       "isError" => true,
       "content" => [
         %{"type" => "text", "text" => Jason.encode!(%{"ok" => false, "error" => error})}
       ]
     }}
  end

  defp tool_result_to_jsonrpc(other) do
    {:ok,
     %{
       "isError" => true,
       "content" => [%{"type" => "text", "text" => Jason.encode!(other)}]
     }}
  end

  # ------------------------------------------------------------------
  # Notification SSE encoding
  # ------------------------------------------------------------------

  defp build_notification_params(payload) do
    # cc_mcp's _handle_inbound built `params: {content, meta}` where
    # `meta` carried the <channel> tag attributes. Mirror that shape
    # here so claude's notification handler renders identical tags.
    meta =
      %{
        "chat_id" => payload["chat_id"],
        "app_id" => payload["app_id"],
        "message_id" => payload["message_id"],
        "user" => payload["user"],
        "ts" => payload["ts"],
        "thread_id" => payload["thread_id"],
        "runtime_mode" => payload["runtime_mode"] || "discussion",
        "source" => payload["source"] || "feishu",
        "user_id" => payload["user_id"],
        "workspace" => payload["workspace"],
        "reachable" => payload["reachable"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.into(%{}, fn {k, v} -> {k, to_string(v)} end)

    %{"content" => payload["content"] || "", "meta" => meta}
  end

  defp encode_sse(method, params) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }

    "event: message\ndata: " <> Jason.encode!(notification) <> "\n\n"
  end

  # ------------------------------------------------------------------
  # JSON-RPC response helpers
  # ------------------------------------------------------------------

  defp send_jsonrpc(conn, req_id, {:ok, result}) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => req_id, "result" => result})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp send_jsonrpc(conn, req_id, {:error, {code, message}}) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => req_id,
        "error" => %{"code" => code, "message" => message}
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp send_jsonrpc_error(conn, req_id, code, message) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => req_id,
        "error" => %{"code" => code, "message" => message}
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # Tiny ULID-ish unique-id generator for tool req_ids. Matches the
  # shape produced by Python's `uuid.uuid4()` well enough — peer code
  # treats req_id as opaque.
  defp ulid do
    bin = :crypto.strong_rand_bytes(16)
    Base.encode16(bin, case: :lower)
  end
end
