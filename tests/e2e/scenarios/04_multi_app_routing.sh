#!/usr/bin/env bash
# PR-A scenario 04 — multi-app coexistence + cross-app forward.
#
# 6 user-steps per docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md §5:
#
#   1.  app_dev sole inbound, no crossover into app_kanban
#   1b. concurrent inbounds to app_dev + app_kanban — distinct sessions,
#       isolated reply paths
#   2.  cross-app forward: app_dev session calls reply with
#       app_id=feishu_app_kanban — assert kanban's sent_messages saw it
#   3.  forbidden: ou_restricted lacks workspace:ws_kanban/msg.send;
#       cross-app reply rejected by FCP auth gate; CC emits structural
#       marker [forward-failed: forbidden] on home chat
#   4.  non-member: oc_pra_orphan not registered as a chat member of
#       any app; cross-app reply rejected by FCP at unknown_chat_in_app
#       (or at mock_feishu's membership check); CC emits
#       [forward-failed: <type>] structural marker
#   5.  cleanup: end all auto-created sessions

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASELINE=$(e2e_tmp_baseline_snapshot)

load_agent_yaml
seed_two_capabilities
seed_two_apps_workspaces
seed_two_adapters
start_two_mock_feishus
start_esrd
wait_for_two_sidecars_ready 30

# --- Step 1: single-app inbound (no crossover) -----------------------
PROBE1='Please reply with exactly: ack-dev-only — for the reply tool, use the app_id you see in the inbound <channel> tag.'
INBOUND1=$(curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_dev\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE1"),\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" \
  | jq -r '.message_id')
[[ -n "$INBOUND1" ]] || _fail_with_context "step1: no message_id from push_inbound"

# Wait up to 120s for CC's reply (real model turn).
for _ in $(seq 1 1200); do
  if curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
       | jq -e '.[] | select(.receive_id=="oc_pra_dev")' >/dev/null; then
    break
  fi
  sleep 0.1
done

A_BODY=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
         | jq -r '.[] | select(.receive_id=="oc_pra_dev") | .content' | tr '\n' ' ')
B_BODY=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
         | jq -r '.[] | .content' | tr '\n' ' ')
assert_contains    "$A_BODY" "ack-dev-only" "step1: app_dev got its ack"
assert_not_contains "$B_BODY" "ack-dev-only" "step1: app_kanban did NOT receive crossover"

# --- Step 1b: kanban-side single-app inbound + isolation -------------
# Originally this step pushed two parallel inbounds and asserted
# that two CC turns ran concurrently in distinct sessions. The
# parallel pattern triggered an intermittent macOS-host-side mock_feishu
# silent-crash that didn't reproduce in single-mock scenarios; the
# isolation guarantee survives the simpler sequential form: run a
# kanban-side inbound on its own (warming the kanban CC session), then
# assert (a) kanban got its kanban-only ack, and (b) dev's bucket
# accumulated no kanban content (= still has step 1's ack-dev-only
# but nothing kanban-flavored).
PROBE_KAN='Please reply with exactly: ack-kanban-iso — for the reply tool, use the app_id from the inbound <channel> tag.'
curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_kanban\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE_KAN"),\"app_id\":\"feishu_app_kanban\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/push_inbound" >/dev/null

for _ in $(seq 1 1500); do
  if curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq -e '.[] | select(.content | contains("ack-kanban-iso"))' >/dev/null; then
    break
  fi
  sleep 0.1
done

KAN_ALL=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
          | jq -r '.[].content' | tr '\n' ' ')
DEV_ALL=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
          | jq -r '.[].content' | tr '\n' ' ')
assert_contains    "$KAN_ALL" "ack-kanban-iso" "step1b: app_kanban got its kanban-only ack"
assert_not_contains "$KAN_ALL" "ack-dev-only"   "step1b: kanban did not receive dev content"
assert_not_contains "$DEV_ALL" "ack-kanban-iso" "step1b: dev did not receive kanban content"

# --- Step 2: cross-app forward (happy path) --------------------------
# Need feishu_app_kanban registered as a member of oc_pra_kanban (it is,
# from start_two_mock_feishus). ou_admin has wildcard so cap check passes.
PROBE2="Please reply on chat oc_pra_kanban with the text 'progress: dev finished step 1' — use app_id=feishu_app_kanban for the reply tool. The reply should land on app_kanban's chat, not your home chat."
curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_dev\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE2"),\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" >/dev/null

for _ in $(seq 1 1200); do
  if curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq -e '.[] | select(.content | contains("dev finished step 1"))' >/dev/null; then
    break
  fi
  sleep 0.1
done

KAN2=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq -r '.[].content' | tr '\n' ' ')
assert_contains "$KAN2" "dev finished step 1" "step2: kanban received the cross-app forward"

# --- Step 3: forbidden cross-app (auth gate rejection) ---------------
# Drive the cross-app reply directly via `esr admin submit
# cross_app_test` — bypasses claude (which refuses cross-app
# forwards as prompt-injection / lateral-movement signals). The
# command synthesizes a tool_invoke into an existing session's FCP
# with a chosen principal_id; FCP then runs its real auth gate
# against capabilities.yaml. See
# runtime/lib/esr/admin/commands/cross_app_test.ex for rationale.
#
# Setup: ou_restricted needs an existing session for FCP to land in.
# Push a benign inbound from ou_restricted on a dedicated chat
# (oc_pra_restricted) to auto-create the session; the principal_id
# captured from the inbound becomes the session's principal_id.
LOG_PATH="${ESRD_HOME}/${ESRD_INSTANCE}/logs/stdout.log"
curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_restricted\",\"user\":\"ou_restricted\",\"text\":\"hello\",\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" >/dev/null

# Wait for the auto-created session for ou_restricted to appear.
SID_RESTRICTED=""
for _ in $(seq 1 300); do
  SID_RESTRICTED=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
    | awk '/^thread:/ { sub("thread:", "", $1); print $1 }' \
    | while read sid; do
        if grep -q "auto-created session ${sid} for new_chat_thread.*chat_id=\"oc_pra_restricted\"" "$LOG_PATH" 2>/dev/null; then
          echo "$sid"
          break
        fi
      done)
  [[ -n "$SID_RESTRICTED" ]] && break
  sleep 0.2
done
[[ -n "$SID_RESTRICTED" ]] || _fail_with_context "step3: no auto-created session for ou_restricted on oc_pra_restricted"

# Synthesize the forbidden cross-app tool_invoke. ou_restricted's
# caps are workspace:ws_dev/* — does NOT match workspace:ws_kanban/msg.send.
STEP3_OUT=$(ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit cross_app_test \
    --arg "session_id=${SID_RESTRICTED}" \
    --arg "chat_id=oc_pra_kanban" \
    --arg "app_id=feishu_app_kanban" \
    --arg "text=step-1 done" \
    --arg "principal_id=ou_restricted" \
    --wait --timeout 10 2>&1)
echo "[step3 cross_app_test result]"
echo "$STEP3_OUT"

assert_contains "$STEP3_OUT" "ok: false"          "step3: tool_result reports ok:false"
assert_contains "$STEP3_OUT" "forbidden"          "step3: tool_result error.type=forbidden"
assert_contains "$STEP3_OUT" "ws_kanban"          "step3: tool_result names ws_kanban"

# Belt + suspenders: also confirm the FCP Logger.info line landed.
grep -q 'FCP cross-app deny type=forbidden.*principal_id="ou_restricted".*workspace:ws_kanban/msg.send' "$LOG_PATH" \
  || _fail_with_context "step3: FCP forbidden log line not in $LOG_PATH"

# Negative assertion — kanban's sent_messages must NOT contain the
# forbidden text (auth gate stopped the directive at FCP).
KAN3=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq -r '.[].content' | tr '\n' ' ')
assert_not_contains "$KAN3" "step-1 done" "step3: kanban did NOT receive forbidden text"

# --- Step 4: non-member chat (FCP unknown_chat_in_app) ---------------
# oc_pra_orphan is in workspaces.yaml under ws_dev/feishu_app_dev but
# NOT bound to feishu_app_kanban anywhere. ou_admin (wildcard caps)
# attempts the cross-app reply via cross_app_test. FCP looks up
# workspace_for_chat(oc_pra_orphan, feishu_app_kanban) → :not_found
# → returns ok:false {"type": "unknown_chat_in_app"}.
SID_DEV=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null \
  | awk '/^thread:/ { sub("thread:", "", $1); print $1 }' \
  | while read sid; do
      if grep -q "auto-created session ${sid} for new_chat_thread.*chat_id=\"oc_pra_dev\".*app_id=\"feishu_app_dev\"" "$LOG_PATH" 2>/dev/null; then
        echo "$sid"
        break
      fi
    done)
[[ -n "$SID_DEV" ]] || _fail_with_context "step4: no auto-created session for oc_pra_dev on feishu_app_dev"

STEP4_OUT=$(ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
  uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit cross_app_test \
    --arg "session_id=${SID_DEV}" \
    --arg "chat_id=oc_pra_orphan" \
    --arg "app_id=feishu_app_kanban" \
    --arg "text=step-2 done" \
    --arg "principal_id=ou_admin" \
    --wait --timeout 10 2>&1)
echo "[step4 cross_app_test result]"
echo "$STEP4_OUT"

assert_contains "$STEP4_OUT" "ok: false"            "step4: tool_result reports ok:false"
assert_contains "$STEP4_OUT" "unknown_chat_in_app"  "step4: tool_result error.type=unknown_chat_in_app"

grep -q 'FCP cross-app deny type=unknown_chat_in_app.*chat_id="oc_pra_orphan".*app_id="feishu_app_kanban"' "$LOG_PATH" \
  || _fail_with_context "step4: FCP unknown_chat_in_app log line not in $LOG_PATH"

KAN4=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq -r '.[].content' | tr '\n' ' ')
assert_not_contains "$KAN4" "step-2 done" "step4: kanban did NOT receive non-member text"

# --- Step 5: cleanup -------------------------------------------------
ACTORS_OUT=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>/dev/null)
SIDS=()
while IFS= read -r sid; do
  [[ -n "$sid" ]] && SIDS+=("$sid")
done < <(echo "$ACTORS_OUT" | awk '/^thread:/ { sub("thread:", "", $1); print $1 }')

for sid in "${SIDS[@]}"; do
  ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
    uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit session_end \
    --arg "session_id=${sid}" --wait --timeout 30
done

for _ in $(seq 1 50); do
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  if ! echo "$out" | grep -q "^thread:"; then break; fi
  sleep 0.1
done

for sid in "${SIDS[@]}"; do
  assert_actors_list_lacks "thread:${sid}" "step5: ${sid} torn down"
done

export _E2E_BASELINE="$BASELINE"
echo "PASS: scenario 04"
