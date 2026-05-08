#!/usr/bin/env bash
# e2e scenario 21 — cc outbound multimedia (claude send_file MCP tool → Feishu file post).
#
# Spec: docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md
#
# WHAT THIS TEST PROVES:
#   - Claude calls the send_file MCP tool via POST /mcp/<sid> JSON-RPC
#   - FeishuChatProxy.dispatch_tool_invoke("send_file", ...) calls
#     Esr.Resource.Media.store → bytes content-addressed at
#     $ESRD_HOME/<env>/resources/image/<sha256>.png
#   - α-wire preserved (D4): Python sidecar receives the send_file
#     directive with file_name + content_b64 + sha256
#   - Sidecar uploads to mock_feishu /open-apis/im/v1/files → receives
#     file_key, then POSTs /open-apis/im/v1/messages with msg_type=file
#   - mock_feishu records the message; sent_files shows sha256 match
#
# COMPLEMENTS scenario 20 (Feishu inbound multimedia).
#
# SESSION SETUP STRATEGY:
#   Unlike scenario 20 (inbound-only, no live session needed), sending
#   via MCP requires a live thread:<sid> peer. The cleanest path is:
#     1. Push an inbound message so the session router spawns a real
#        FeishuChatProxy with chat_id=oc_mock_single bound.
#     2. Capture the auto-created session_id from the actors list.
#     3. POST /mcp/<sid> to invoke send_file — FCP handles the tool
#        invoke, stores bytes, emits α-wire → Python sidecar → mock.
#   (Creating a session via `session_new` without chat_id takes the
#   "pending" branch and spawns NO FeishuChatProxy — no send_file handler.)
#
# INVARIANT GATE:
#   bash tests/e2e/scenarios/21_cc_outbound_multimedia.sh 2>&1 | tail -3
#   → ends with "PASS: 21_cc_outbound_multimedia"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
# Use a slim agents.yaml with only feishu_chat_proxy in the pipeline
# (no CCProcess / PtyProcess). This avoids the PtyProcess trying to
# launch `claude` (which isn't running in this test), while still
# giving us a live FCP that registers as thread:<sid> and handles
# send_file tool invocations. Multi_app fixture shape is the model.
_seed_agent_yaml_fcp_only() {
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
  cat > "${ESRD_HOME}/${ESRD_INSTANCE}/agents.yaml" <<'AGENTS'
agents:
  cc:
    description: "FCP-only agent for outbound multimedia e2e"
    capabilities_required:
      - session:default/create
      - peer_proxy:feishu/forward
    pipeline:
      inbound:
        - name: feishu_chat_proxy
          impl: Esr.Entity.FeishuChatProxy
      outbound:
        - feishu_chat_proxy
    proxies:
      - name: feishu_app_proxy
        impl: Esr.Entity.FeishuAppProxy
        target: "admin::feishu_app_adapter_${app_id}"
    params:
      - name: dir
        required: true
        type: path
      - name: app_id
        required: false
        default: "default"
        type: string
AGENTS
}

_seed_agent_yaml_fcp_only
seed_plugin_config
seed_capabilities
seed_workspaces           # maps oc_mock_single → workspace e2e (app_id: e2e-mock)
seed_adapters             # registers feishu_app_e2e-mock with base_url → mock_feishu
start_mock_feishu         # starts on MOCK_FEISHU_PORT (default 8201) + seeds memberships
start_esrd

# Wait for the feishu adapter sidecar to connect to mock_feishu's WS.
wait_for_sidecar_ready 30

# --- step 1: create session via session_new with chat_id bound --------
# Passing chat_id + app_id causes Commands.Scope.New to take the
# chat-bound branch → Scope.Router.create_session → full pipeline spawn
# including FeishuChatProxy (which registers as thread:<sid> in its
# init). This avoids the new_chat_thread async path and the actors list
# routing issue (actors_list vs actor_list kind mismatch).
CHAT_ID="oc_mock_single"
APP_ID="feishu_app_e2e-mock"
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-21"
mkdir -p "${WORKDIR}"

echo "21: creating session with chat_id=${CHAT_ID} app_id=${APP_ID}"

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --wait --timeout 30)

echo "21: session_new output: ${SESSION_OUT}"
assert_contains "${SESSION_OUT}" "ok: true" "21: session_new ok"

SID=$(echo "${SESSION_OUT}" | awk -F': ' '/^session_id:/ {print $2; exit}' | tr -d '"')
[[ -n "$SID" ]] || _fail_with_context "21: no session_id from session_new"
echo "21: live session_id: ${SID}"

# Give FCP a brief moment to complete its init/registration. The session
# router returns after pipeline spawn, but FCP's Registry.register runs
# inside its own init; tiny sleep ensures the registration is visible.
sleep 0.3

# --- step 3: prepare fixture -----------------------------------------
FIXTURE="$(cd "${SCRIPT_DIR}/../fixtures" && pwd)/test_image.png"
[[ -f "${FIXTURE}" ]] || _fail_with_context "21: missing fixture ${FIXTURE}"

EXPECTED_SHA=$(shasum -a 256 "${FIXTURE}" | awk '{print $1}')
EXPECTED_BYTES_LEN=$(wc -c < "${FIXTURE}" | tr -d ' ')

echo "21: fixture sha=${EXPECTED_SHA}, ${EXPECTED_BYTES_LEN} bytes"

# --- step 4: invoke send_file via MCP --------------------------------
PORT_FILE="${ESRD_HOME}/${ESRD_INSTANCE}/esrd.port"
[[ -r "${PORT_FILE}" ]] || _fail_with_context "21: esrd.port file not found at ${PORT_FILE}"
ESRD_PORT=$(cat "${PORT_FILE}")

echo "21: invoking send_file via POST /mcp/${SID} on port ${ESRD_PORT}"

MCP_RESP=$(curl -sS --connect-timeout 2 --max-time 35 \
  -X POST \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
        --arg path "${FIXTURE}" \
        --arg chat "${CHAT_ID}" \
        '{jsonrpc: "2.0", id: 1, method: "tools/call",
          params: {name: "send_file",
                   arguments: {chat_id: $chat, file_path: $path}}}')" \
  "http://127.0.0.1:${ESRD_PORT}/mcp/${SID}")

echo "21: MCP response: ${MCP_RESP}"

# The JSON-RPC result from tools/call wraps the tool result. Success
# means either dispatched=true in the content text OR a result.content
# array with no isError=true. Check for "dispatched" in the raw response.
echo "${MCP_RESP}" | jq -e '.result.content[0].text | fromjson | .dispatched == true' >/dev/null \
  || _fail_with_context "21: send_file MCP call did not return dispatched=true. response: ${MCP_RESP}"

# --- step 5: wait for content-addressed file at cc-side store --------
# FeishuChatProxy stores the bytes before emitting the α-wire, so the
# file should appear immediately after the MCP call returns.
EXPECTED_FILE="${ESRD_HOME}/${ESR_INSTANCE}/resources/image/${EXPECTED_SHA}.png"
echo "21: waiting for ${EXPECTED_FILE}"

FOUND=0
for i in $(seq 1 60); do
  if [[ -f "${EXPECTED_FILE}" ]]; then
    FOUND=1
    break
  fi
  sleep 0.5
done

if [[ "$FOUND" -ne 1 ]]; then
  echo "21: timed out waiting for content-addressed file" >&2
  echo "21: resources dir listing:" >&2
  ls -la "${ESRD_HOME}/${ESR_INSTANCE}/resources/" 2>/dev/null || \
    echo "  (resources dir does not exist)" >&2
  ls -la "${ESRD_HOME}/${ESR_INSTANCE}/resources/image/" 2>/dev/null || \
    echo "  (resources/image dir does not exist)" >&2
  _fail_with_context "21: content-addressed file not found after 30s: ${EXPECTED_FILE}"
fi

assert_file_exists "${EXPECTED_FILE}"

# --- step 6: verify stored bytes match fixture -----------------------
ACTUAL_SHA=$(shasum -a 256 "${EXPECTED_FILE}" | awk '{print $1}')
assert_eq "${ACTUAL_SHA}" "${EXPECTED_SHA}" "21: stored bytes match fixture sha256"

ACTUAL_LEN=$(wc -c < "${EXPECTED_FILE}" | tr -d ' ')
assert_eq "${ACTUAL_LEN}" "${EXPECTED_BYTES_LEN}" "21: stored bytes length matches"

# refs.jsonl must have at least one entry (source_actor=cc)
REFS_FILE="${ESRD_HOME}/${ESR_INSTANCE}/resources/image/${EXPECTED_SHA}.refs.jsonl"
assert_file_exists "${REFS_FILE}"

REF_COUNT=$(wc -l < "${REFS_FILE}" | tr -d ' ')
[[ "${REF_COUNT}" -ge 1 ]] || _fail_with_context "21: refs.jsonl empty"

REF_LINE=$(head -1 "${REFS_FILE}")
echo "21: ref entry: ${REF_LINE}"

REF_SOURCE=$(echo "${REF_LINE}" | jq -r '.source_actor // empty')
assert_eq "${REF_SOURCE}" "cc" "21: ref.source_actor == cc"

REF_CHAT=$(echo "${REF_LINE}" | jq -r '.chat_id // empty')
assert_eq "${REF_CHAT}" "${CHAT_ID}" "21: ref.chat_id matches"

REF_SESSION=$(echo "${REF_LINE}" | jq -r '.session_id // empty')
[[ -n "${REF_SESSION}" ]] || _fail_with_context "21: ref.session_id must be set"

# --- step 7: wait for mock_feishu to receive the outbound message -----
# Python sidecar's _send_file: upload → file_key → POST messages with
# msg_type=file. Wait for sent_files to show a linked entry for our chat.
echo "21: waiting for mock_feishu sent_files for chat=${CHAT_ID}"

LINKED=0
for i in $(seq 1 60); do
  SF_COUNT=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_files" \
    | jq --arg cid "${CHAT_ID}" '[.[] | select(.chat_id==$cid)] | length' 2>/dev/null || echo 0)
  if [[ "${SF_COUNT}" -ge 1 ]]; then
    LINKED=1
    break
  fi
  sleep 0.5
done

if [[ "$LINKED" -ne 1 ]]; then
  echo "21: sent_files never populated for chat ${CHAT_ID}" >&2
  echo "21: full sent_files:" >&2
  curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_files" >&2 || true
  echo "21: full sent_messages:" >&2
  curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" >&2 || true
  _fail_with_context "21: mock_feishu sent_files empty for chat=${CHAT_ID} after 30s"
fi

# sha256 of the uploaded file must match the fixture
assert_mock_feishu_file_sha "${CHAT_ID}" "${EXPECTED_SHA}"

# --- step 8: verify sent_messages has a file message for our chat ----
SENT=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages")
echo "21: sent_messages sample: $(echo "${SENT}" | jq 'length') messages total"

echo "${SENT}" | jq -e \
  --arg cid "${CHAT_ID}" \
  '.[] | select(.receive_id==$cid and .msg_type=="file")' >/dev/null \
  || _fail_with_context "21: no msg_type=file message to ${CHAT_ID} in sent_messages"

# Extract file_key from the message content and verify it matches a
# sent_files entry with the correct sha256.
FILE_KEY=$(echo "${SENT}" | jq -r \
  --arg cid "${CHAT_ID}" \
  '[.[] | select(.receive_id==$cid and .msg_type=="file")][0].content | fromjson | .file_key // empty')
[[ -n "${FILE_KEY}" ]] || _fail_with_context "21: file_key missing from message content"
echo "21: file_key=${FILE_KEY}"

UPLOADED_SHA=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_files" \
  | jq -r --arg fk "${FILE_KEY}" '.[] | select(.file_key==$fk) | .sha256 // empty')
[[ -n "${UPLOADED_SHA}" ]] || _fail_with_context "21: file_key ${FILE_KEY} not found in sent_files"
assert_eq "${UPLOADED_SHA}" "${EXPECTED_SHA}" "21: uploaded bytes sha256 matches fixture"

echo "PASS: 21_cc_outbound_multimedia"
