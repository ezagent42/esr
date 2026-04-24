#!/usr/bin/env bash
# PR-7 scenario 02 — two concurrent users, session isolation.
# See spec §3.3 + §9 user-steps 7-8.
#
# T12-comms-3k rewrite (2026-04-24): post-T11b architecture auto-creates
# sessions on first inbound. Drop the pre-create `/new-session ...` dance
# (which was the pre-T11b multi-tag model) — send two independent
# inbounds to distinct chat_ids and assert isolation on the replies.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASELINE=$(e2e_tmp_baseline_snapshot)

load_agent_yaml
seed_capabilities
seed_workspaces
seed_adapters
start_mock_feishu
start_esrd
wait_for_sidecar_ready 30

# Distinct content markers so isolation violations are unambiguous.
PROBE_A="Please reply with exactly: ack-alpha-uniq"
PROBE_B="Please reply with exactly: ack-beta-uniq"

# Fire both inbounds in parallel — session_router auto-creates two
# independent pipelines for oc_mock_concurrent_a and oc_mock_concurrent_b.
curl -sS -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_mock_concurrent_a\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE_A")}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" >/dev/null &
PID_A=$!
curl -sS -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_mock_concurrent_b\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE_B")}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" >/dev/null &
PID_B=$!
wait "$PID_A" "$PID_B"

# Wait up to 120s for both replies (two real CC turns in parallel).
for _ in $(seq 1 1200); do
  replies_a=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
    | jq '[.[] | select(.receive_id=="oc_mock_concurrent_a")] | length')
  replies_b=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
    | jq '[.[] | select(.receive_id=="oc_mock_concurrent_b")] | length')
  [[ "$replies_a" -ge 1 && "$replies_b" -ge 1 ]] && break
  sleep 0.1
done
[[ "$replies_a" -ge 1 ]] || _fail_with_context "user-step 7: no reply for oc_mock_concurrent_a"
[[ "$replies_b" -ge 1 ]] || _fail_with_context "user-step 7: no reply for oc_mock_concurrent_b"

# --- isolation assertions --------------------------------------------
SENT=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages")
A_BODY=$(echo "$SENT" | jq -r '.[] | select(.receive_id=="oc_mock_concurrent_a") | .content' | tr '\n' ' ')
B_BODY=$(echo "$SENT" | jq -r '.[] | select(.receive_id=="oc_mock_concurrent_b") | .content' | tr '\n' ' ')

assert_contains "$A_BODY" "ack-alpha-uniq" "user-step 7: alpha got its own ack"
assert_contains "$B_BODY" "ack-beta-uniq"  "user-step 7: beta got its own ack"
assert_not_contains "$A_BODY" "ack-beta-uniq"  "user-step 7: alpha contaminated with beta content"
assert_not_contains "$B_BODY" "ack-alpha-uniq" "user-step 7: beta contaminated with alpha content"

# --- user-step 8: end both sessions ----------------------------------
# Capture the two auto-created session_ids from the live actor list.
ACTORS_OUT=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null)
readarray -t SIDS < <(echo "$ACTORS_OUT" | awk '/^thread:/ { sub("thread:", "", $1); print $1 }')
[[ "${#SIDS[@]}" -eq 2 ]] \
  || _fail_with_context "user-step 8: expected 2 thread:<sid> actors, saw ${#SIDS[@]}"

for sid in "${SIDS[@]}"; do
  ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
    uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit session_end \
    --arg "session_id=${sid}" \
    --wait --timeout 30
done

for _ in $(seq 1 50); do
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  if ! echo "$out" | grep -q "^thread:"; then
    break
  fi
  sleep 0.1
done
for sid in "${SIDS[@]}"; do
  assert_actors_list_lacks "thread:${sid}" "user-step 8: ${sid} torn down"
done

export _E2E_BASELINE="$BASELINE"

echo "PASS: scenario 02"
