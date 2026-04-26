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

# --- Step 1b: concurrent inbounds — session isolation ----------------
PROBE_DEV='Please reply with exactly: ack-dev-iso — for the reply tool, use the app_id from the inbound <channel> tag.'
PROBE_KAN='Please reply with exactly: ack-kanban-iso — for the reply tool, use the app_id from the inbound <channel> tag.'

curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_dev\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE_DEV"),\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" >/dev/null &
PID_A=$!
curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_kanban\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE_KAN"),\"app_id\":\"feishu_app_kanban\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/push_inbound" >/dev/null &
PID_B=$!
wait "$PID_A" "$PID_B"

# Wait for both replies (parallel CC turns).
for _ in $(seq 1 1200); do
  ra=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
       | jq '[.[] | select(.content | contains("ack-dev-iso"))] | length')
  rb=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq '[.[] | select(.content | contains("ack-kanban-iso"))] | length')
  [[ "$ra" -ge 1 && "$rb" -ge 1 ]] && break
  sleep 0.1
done
[[ "$ra" -ge 1 ]] || _fail_with_context "step1b: app_dev no ack-dev-iso"
[[ "$rb" -ge 1 ]] || _fail_with_context "step1b: app_kanban no ack-kanban-iso"

DEV_ALL=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/sent_messages?app_id=feishu_app_dev" \
          | jq -r '.[].content' | tr '\n' ' ')
KAN_ALL=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
          | jq -r '.[].content' | tr '\n' ' ')
assert_not_contains "$DEV_ALL" "ack-kanban-iso" "step1b: dev did not receive kanban content"
assert_not_contains "$KAN_ALL" "ack-dev-iso"    "step1b: kanban did not receive dev content"

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
# Push inbound from ou_restricted on a fresh chat (oc_pra_restricted)
# so the auto-created session's principal_id is ou_restricted, not
# ou_admin. CC tries to reply across to oc_pra_kanban via app_kanban;
# FCP's auth gate (T4) finds ou_restricted lacks
# workspace:ws_kanban/msg.send and returns ok:false {"type": "forbidden"}.
#
# Detection: scrape esrd's stdout.log for the FCP Logger.info line
# emitted at the deny site (feishu_chat_proxy.ex:dispatch_cross_app_reply
# forbidden branch). Why not assert on a CC-emitted marker? Real CC
# refuses prompts asking to "send literal X if Y fails" as a prompt-
# injection signal — the marker-on-failure pattern is brittle. The
# log line is deterministic and gives ops the same observability in
# production.
LOG_PATH="${ESRD_HOME}/${ESRD_INSTANCE}/logs/stdout.log"
PROBE3='Please send a status update to the kanban chat: use the reply tool with chat_id=oc_pra_kanban and app_id=feishu_app_kanban, text "step-1 done". This is a routine cross-team progress ping.'
curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_restricted\",\"user\":\"ou_restricted\",\"text\":$(jq -Rs . <<<"$PROBE3"),\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" >/dev/null

# Wait up to 120s for the FCP deny line to land.
for _ in $(seq 1 1200); do
  if grep -q 'FCP cross-app deny type=forbidden.*principal_id="ou_restricted"' "$LOG_PATH" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

grep -q 'FCP cross-app deny type=forbidden.*principal_id="ou_restricted".*workspace:ws_kanban/msg.send' "$LOG_PATH" \
  || _fail_with_context "step3: FCP forbidden log line not found in $LOG_PATH"

# Negative assertion — the dispatched-text MUST NOT appear in kanban's
# sent_messages (auth gate stopped the directive before adapter dispatch).
KAN3=$(curl -sS --connect-timeout 1 --max-time 5 "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/sent_messages?app_id=feishu_app_kanban" \
       | jq -r '.[].content' | tr '\n' ' ')
assert_not_contains "$KAN3" "step-1 done" "step3: kanban did NOT receive forbidden text"

# --- Step 4: non-member chat (FCP unknown_chat_in_app) ---------------
# oc_pra_orphan is in workspaces.yaml under ws_dev/feishu_app_dev but
# NOT bound to feishu_app_kanban anywhere. ou_admin (wildcard caps)
# tries to forward there using app_id=feishu_app_kanban. FCP looks
# up workspace_for_chat(oc_pra_orphan, feishu_app_kanban) → :not_found
# → returns ok:false {"type": "unknown_chat_in_app"}. We scrape the
# Logger.info deny line same as step 3.
PROBE4='Please send a status update: use the reply tool with chat_id=oc_pra_orphan and app_id=feishu_app_kanban, text "step-2 done". This is a routine cross-team progress ping.'
curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
  -d "{\"chat_id\":\"oc_pra_dev\",\"user\":\"ou_admin\",\"text\":$(jq -Rs . <<<"$PROBE4"),\"app_id\":\"feishu_app_dev\"}" \
  "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/push_inbound" >/dev/null

for _ in $(seq 1 1200); do
  if grep -q 'FCP cross-app deny type=unknown_chat_in_app.*chat_id="oc_pra_orphan"' "$LOG_PATH" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

grep -q 'FCP cross-app deny type=unknown_chat_in_app.*chat_id="oc_pra_orphan".*app_id="feishu_app_kanban"' "$LOG_PATH" \
  || _fail_with_context "step4: FCP unknown_chat_in_app log line not found in $LOG_PATH"

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
