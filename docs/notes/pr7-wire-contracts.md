# PR-7 wire contracts (frozen)

Pinned by plan T0 on 2026-04-23; all of B, C, D1, D2 consume these
shapes as-is. Any change to this file requires re-ordering the
downstream tasks.

## 1. `channel_adapter` parsing

Source: `agents.yaml` `proxies[].target`, e.g.:

```yaml
proxies:
  - name: feishu_app_proxy
    impl: Esr.Peers.FeishuAppProxy
    target: "admin::feishu_app_adapter_${app_id}"
```

**Parsing decision (frozen):** the regex captures the entire token up
to `_adapter_` (i.e. `feishu_app`), not just `feishu`. Rationale: the
review surfaced this greediness explicitly; we accept `feishu_app` as
the adapter family rather than add anchoring that diverges from how
the admin-peer-name already combines app+adapter. Downstream consumers
(Python adapter; emit payload) treat the family as an opaque token.

```
target := "admin::<adapter_family>_adapter_<app_id>"
regex  := ~r/^admin::([a-z_]+)_adapter_.*$/
```

- Match on `"admin::feishu_app_adapter_default"` → capture group 1
  equals `"feishu_app"`.
- Non-matching targets fall back to `"feishu"` with a
  `Logger.warning`.

**Test cases (D1 must cover all four):**

| Input target | Expected `channel_adapter` | Log? |
|--------------|----------------------------|------|
| `"admin::feishu_app_adapter_default"` | `"feishu_app"` | no |
| `"admin::feishu_app_adapter_e2e-mock"` | `"feishu_app"` | no |
| `"admin::slack_v2_adapter_acme"` | `"slack_v2"` | no |
| `"admin::malformed-no-underscore"` | `"feishu"` (fallback) | warning |

## 2. `react` directive emit shape (D2, correcting §5.1 bug)

**Input** (what CC's MCP tool passes — UNCHANGED):

```json
{"message_id": "om_xxx", "emoji_type": "THUMBSUP"}
```

**Emit** (Elixir → adapter — CHANGED: `message_id`→`msg_id`):

```elixir
%{
  "type" => "emit",
  "adapter" => session_channel_adapter(state),
  "action" => "react",
  "args" => %{"msg_id" => mid, "emoji_type" => emoji}
}
```

Adapter reads `args["msg_id"]` (matches `_pin`, `_unpin`, `_download_file`
convention).

## 3. `send_file` directive emit shape (D2, §6.2 α shape)

**Input** (MCP tool — UNCHANGED):

```json
{"chat_id": "oc_xxx", "file_path": "/abs/path"}
```

**Emit** (Elixir → adapter — base64 in-band):

```elixir
%{
  "type" => "emit",
  "adapter" => session_channel_adapter(state),
  "action" => "send_file",
  "args" => %{
    "chat_id" => cid,
    "file_name" => Path.basename(fp),
    "content_b64" => Base.encode64(bytes),
    "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  }
}
```

Error shape: `{:error, "send_file cannot read <path>: <reason>"}` on
read failure.

## 4. Mock Feishu endpoints (B)

### 4a. `POST /open-apis/im/v1/messages/:message_id/reactions`

Body: `{"reaction_type": {"emoji_type": "THUMBSUP"}}`
Response: `{"code": 0, "msg": "", "data": {"reaction_id": "rc_mock_<hex>", "message_id": "<id>"}}`
Side effect: append `{message_id, emoji_type, ts_unix_ms}` to
`self._reactions`.

### 4b. `GET /reactions`

Response: `[{"message_id": "...", "emoji_type": "...", "ts_unix_ms": ...}, ...]`
(newest-last).

### 4c. `POST /open-apis/im/v1/files`

Multipart/form-data OR JSON body with:
- `file_type`: `"stream"`
- `file_name`: string
- `file` (multipart) OR `content_b64` (JSON): bytes

Response: `{"code": 0, "msg": "", "data": {"file_key": "file_mock_<hex>"}}`
Side effect: persist bytes to `/tmp/mock-feishu-files-<port>/<file_key>`;
append `{chat_id: "", file_key, file_name, size, sha256, ts_unix_ms}`
to `self._uploaded_files` (chat_id is set to `""` at upload time —
filled in on the follow-up send-message call).

### 4d. `POST /open-apis/im/v1/messages?receive_id_type=chat_id` (msg_type=file extension)

Body: `{"receive_id": "oc_xxx", "msg_type": "file", "content": "{\"file_key\": \"...\"}"}`
Side effect: look up the file_key in `self._uploaded_files`, back-fill
`chat_id = receive_id`. Response identical to existing text-message path.

### 4e. `GET /sent_files`

Response: `[{"chat_id": "...", "file_key": "...", "file_name": "...", "size": N, "sha256": "...", "ts_unix_ms": ...}, ...]`
Only entries whose chat_id is non-empty (i.e. already linked to a
send-message call).

## 5. `ESR_E2E_TMUX_SOCK` env → Application env (J1)

Boot-time reader in `application.ex` (early in `start/2`, before the
`children` list is built so the env is set before any peer
spawn):

```elixir
case System.get_env("ESR_E2E_TMUX_SOCK") do
  nil -> :ok
  ""  -> :ok
  path ->
    Application.put_env(:esr, :tmux_socket_override, path)
end
```

Consumer in `tmux_process.ex::spawn_args/1`:

```elixir
case Esr.Peer.get_param(params, :tmux_socket) ||
       Application.get_env(:esr, :tmux_socket_override) do
  nil  -> base
  path -> Map.put(base, :tmux_socket, path)
end
```

Observable invariant (J1 test target): after
`Application.put_env(:esr, :tmux_socket_override, "/tmp/foo.sock")`,
`TmuxProcess.spawn_args(%{})` returns a map containing
`tmux_socket: "/tmp/foo.sock"`.

## 6. `cli:actors/inspect --field` (H)

Extension to `EsrWeb.CliChannel.dispatch/2`. Accepts a payload with
`{"arg" => actor_id, "field" => "state.session_name"}`. Response shape:

```json
{"data": {"actor_id": "...", "field": "state.session_name", "value": "esr_cc_42"}}
```

Resolution: `get_in(describe_map, String.split(field, "."))`. Missing
key → `{"data": {"error": "field not present", "field": "<f>"}}`.
