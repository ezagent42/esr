#!/usr/bin/env bash
# e2e scenario 20 — Feishu inbound multimedia (image).
#
# Spec: docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md
#
# WHAT THIS TEST PROVES:
#   - Operator pastes a PNG via Feishu inbound → mock_feishu emits
#     P2ImMessageReceiveV1 with msg_type=image
#   - Feishu adapter sidecar's _download_file directive fetches bytes
#     via mock's GET /open-apis/im/v1/messages/<msg_id>/resources/<file_key>
#   - Bytes are content-addressed at
#     $ESRD_HOME/<env>/resources/image/<sha256>.png
#   - <sha256>.refs.jsonl has one ref entry with chat_id, adapter,
#     file_name, and received_at
#   - The downloaded file's bytes match the original PNG fixture
#
# INVARIANT GATE:
#   bash tests/e2e/scenarios/20_feishu_inbound_multimedia.sh 2>&1 | tail -3
#   → ends with "PASS: 20_feishu_inbound_multimedia"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
seed_workspaces           # maps oc_mock_single → workspace e2e (app_id: e2e-mock)
seed_adapters             # registers feishu_app_e2e-mock with base_url → mock_feishu
start_mock_feishu         # starts on MOCK_FEISHU_PORT (default 8201) + seeds memberships
start_esrd

# Wait for the feishu adapter sidecar to connect to mock_feishu's WS.
# Uses the same /ws_clients probe as scenarios 01-03.
wait_for_sidecar_ready 30

# --- step 1: prepare fixture + push image inbound --------------------
FIXTURE="${SCRIPT_DIR}/../fixtures/test_image.png"
[[ -f "${FIXTURE}" ]] || _fail_with_context "20: missing fixture ${FIXTURE}"

EXPECTED_SHA=$(shasum -a 256 "${FIXTURE}" | awk '{print $1}')
EXPECTED_BYTES_LEN=$(wc -c < "${FIXTURE}" | tr -d ' ')
BYTES_B64=$(base64 < "${FIXTURE}" | tr -d '\n')

echo "20: pushing image inbound (sha=${EXPECTED_SHA}, ${EXPECTED_BYTES_LEN} bytes)"

# seed_workspaces uses oc_mock_single + app_id e2e-mock.
# seed_adapters registers feishu_app_e2e-mock; its app_id is "e2e-mock".
# push_inbound with explicit app_id routes to the correct WS bucket.
CHAT_ID="oc_mock_single"
SENDER_ID="ou_admin"
APP_ID="e2e-mock"

INBOUND_RESP=$(curl -sS --connect-timeout 1 --max-time 10 \
  -X POST -H 'Content-Type: application/json' \
  -d "$(jq -n \
        --arg chat "${CHAT_ID}" \
        --arg user "${SENDER_ID}" \
        --arg app  "${APP_ID}" \
        --arg b64  "${BYTES_B64}" \
        '{chat_id: $chat, user: $user, app_id: $app,
          msg_type: "image", file_name: "test_image.png",
          bytes_b64: $b64}')" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound")

echo "20: push_inbound response: ${INBOUND_RESP}"
MSG_ID=$(echo "${INBOUND_RESP}" | jq -r '.message_id // empty')
[[ -n "$MSG_ID" ]] || _fail_with_context "20: no message_id in push_inbound response"

# --- step 2: wait for content-addressed file to appear ---------------
EXPECTED_FILE="${ESRD_HOME}/${ESR_INSTANCE}/resources/image/${EXPECTED_SHA}.png"
echo "20: waiting for ${EXPECTED_FILE}"

FOUND=0
for i in $(seq 1 60); do
  if [[ -f "${EXPECTED_FILE}" ]]; then
    FOUND=1
    break
  fi
  sleep 0.5
done

if [[ "$FOUND" -ne 1 ]]; then
  echo "20: timed out waiting for content-addressed file" >&2
  echo "20: resources dir listing:" >&2
  ls -la "${ESRD_HOME}/${ESR_INSTANCE}/resources/" 2>/dev/null || \
    echo "  (resources dir does not exist)" >&2
  ls -la "${ESRD_HOME}/${ESR_INSTANCE}/resources/image/" 2>/dev/null || \
    echo "  (resources/image dir does not exist)" >&2
  _fail_with_context "20: content-addressed file not found after 30s: ${EXPECTED_FILE}"
fi

assert_file_exists "${EXPECTED_FILE}"

# --- step 3: verify bytes match --------------------------------------
ACTUAL_SHA=$(shasum -a 256 "${EXPECTED_FILE}" | awk '{print $1}')
assert_eq "${ACTUAL_SHA}" "${EXPECTED_SHA}" "20: stored bytes match fixture sha256"

ACTUAL_LEN=$(wc -c < "${EXPECTED_FILE}" | tr -d ' ')
assert_eq "${ACTUAL_LEN}" "${EXPECTED_BYTES_LEN}" "20: stored bytes length matches"

# --- step 4: verify refs.jsonl has one entry with expected fields ----
REFS_FILE="${ESRD_HOME}/${ESR_INSTANCE}/resources/image/${EXPECTED_SHA}.refs.jsonl"
assert_file_exists "${REFS_FILE}"

REF_COUNT=$(wc -l < "${REFS_FILE}" | tr -d ' ')
assert_eq "${REF_COUNT}" "1" "20: refs.jsonl has one entry"

REF_LINE=$(head -1 "${REFS_FILE}")
echo "20: ref entry: ${REF_LINE}"

REF_CHAT=$(echo "${REF_LINE}" | jq -r '.chat_id // empty')
REF_FILE_NAME=$(echo "${REF_LINE}" | jq -r '.file_name // empty')
REF_ADAPTER=$(echo "${REF_LINE}" | jq -r '.adapter // empty')
REF_RECEIVED=$(echo "${REF_LINE}" | jq -r '.received_at // empty')

assert_eq "${REF_ADAPTER}" "feishu" "20: ref.adapter == feishu"
assert_eq "${REF_CHAT}" "${CHAT_ID}" "20: ref.chat_id matches push"
assert_eq "${REF_FILE_NAME}" "test_image.png" "20: ref.file_name preserved"
[[ -n "${REF_RECEIVED}" ]] || _fail_with_context "20: ref.received_at must be set"

echo "PASS: 20_feishu_inbound_multimedia"
