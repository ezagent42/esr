#!/usr/bin/env bash
# PR-E scenario 05 — actor-topology-routing wire e2e.
#
# Validates the addressability layer of PR-B (URI migration), PR-C
# (Topology + reachable_set + BGP learn + tag rendering), and PR-D
# (cc_mcp meta whitelist + JSON-string `reachable` attribute) end-to-end
# with real esrd + mock_feishu, *without* depending on real-claude
# prompt behaviour.
#
# Coverage (8 assertions, two groups):
#
# A. Configuration-layer multi-hop — yaml `neighbors:` chain with
#    1-hop symmetric closure (per spec §6.4):
#      A1. ws_alpha session reaches ws_bravo (declared neighbour)
#      A2. ws_alpha session does NOT reach ws_charlie (transitive
#          NOT applied — proves 1-hop discipline)
#      A3. ws_bravo session reaches ws_charlie (its own next hop)
#      A4. ws_bravo session reaches ws_alpha (reverse symmetric)
#      A5. ws_charlie session does NOT reach ws_alpha (no transitive
#          two-hop discovery — pins spec §6.4 design)
#
# B. Runtime-layer BGP propagation — same session learning new
#    user URIs from inbound `principal_id` over time:
#      B1. first inbound (user=ou_admin) → learned URIs include
#          `esr://localhost/users/ou_admin`
#      B2. second inbound (user=ou_visitor, different sender) →
#          learned URIs include the new user URI
#      B3. second learn does NOT re-include ou_admin (already known —
#          idempotent set semantics)
#
# Out of scope (deferred to PR-F):
#   - Business-topology LLM awareness (knowing your stage in a
#     pipeline). See docs/notes/actor-topology-routing.md
#     "known limitations" + task #150 for the follow-up grill.
#   - Real-claude behavioural validation that the LLM uses
#     `reachable` for routing decisions — manual smoke check.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASELINE=$(e2e_tmp_baseline_snapshot)

load_agent_yaml
seed_two_capabilities
seed_two_apps_workspaces

# Override the seeded workspaces.yaml with a 3-workspace chain that
# reuses the chat memberships already registered by
# seed_two_apps_workspaces (oc_pra_dev / oc_pra_kanban /
# oc_pra_restricted). The chain shape: alpha → bravo → charlie.
mkdir -p "${ESRD_HOME}/default" "${ESRD_HOME}/${ESRD_INSTANCE}"
ws_yaml=$(cat <<'EOF'
workspaces:
  ws_alpha:
    root: "/tmp/esr-e2e-workspace-alpha"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_pra_dev, app_id: feishu_app_dev, kind: dm, name: alpha-room}
    neighbors:
      - workspace:ws_bravo
    env: {}
  ws_bravo:
    root: "/tmp/esr-e2e-workspace-bravo"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_pra_kanban, app_id: feishu_app_kanban, kind: dm, name: bravo-room}
    neighbors:
      - workspace:ws_charlie
    env: {}
  ws_charlie:
    root: "/tmp/esr-e2e-workspace-charlie"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_pra_restricted, app_id: feishu_app_dev, kind: dm, name: charlie-room}
    neighbors: []
    env: {}
EOF
)
printf '%s\n' "$ws_yaml" > "${ESRD_HOME}/default/workspaces.yaml"
printf '%s\n' "$ws_yaml" > "${ESRD_HOME}/${ESRD_INSTANCE}/workspaces.yaml"

seed_two_adapters
start_two_mock_feishus
start_esrd
wait_for_two_sidecars_ready 30

LOG_PATH="${ESRD_HOME}/${ESRD_INSTANCE}/logs/stdout.log"

URI_ALPHA="esr://localhost/workspaces/ws_alpha/chats/oc_pra_dev"
URI_BRAVO="esr://localhost/workspaces/ws_bravo/chats/oc_pra_kanban"
URI_CHARLIE="esr://localhost/workspaces/ws_charlie/chats/oc_pra_restricted"

# Helper: push inbound to a chat and wait for the runtime to dispatch
# the channel notification for its workspace. Counts dispatch lines
# tagged with the expected workspace before vs after the push so
# multiple pushes don't false-positive on the first session's line.
push_and_wait() {
  local port=$1 chat=$2 user=$3 app=$4 expected_workspace=$5

  local before_count=0
  if [[ -f "$LOG_PATH" ]]; then
    before_count=$( { grep "channel notification dispatched.*workspace=\"$expected_workspace\"" "$LOG_PATH" 2>/dev/null || true; } | wc -l | tr -d ' \n')
    [[ -n "$before_count" ]] || before_count=0
  fi

  local probe="probe to $chat ($expected_workspace)"
  curl -sS --connect-timeout 1 --max-time 5 -X POST -H 'content-type: application/json' \
    -d "{\"chat_id\":\"$chat\",\"user\":\"$user\",\"text\":$(jq -Rs . <<<"$probe"),\"app_id\":\"$app\"}" \
    "http://127.0.0.1:${port}/push_inbound" >/dev/null \
    || _fail_with_context "push_inbound to $chat failed"

  # Wait up to 60s for THIS push's dispatch line. Polls dispatch-line
  # count tagged with the expected workspace; succeeds when it grows.
  for _ in $(seq 1 600); do
    local now_count=0
    if [[ -f "$LOG_PATH" ]]; then
      now_count=$( { grep "channel notification dispatched.*workspace=\"$expected_workspace\"" "$LOG_PATH" 2>/dev/null || true; } | wc -l | tr -d ' \n')
      [[ -n "$now_count" ]] || now_count=0
    fi
    if [[ "$now_count" -gt "$before_count" ]]; then
      sleep 0.3
      return 0
    fi
    sleep 0.1
  done
  _fail_with_context "push_and_wait: no dispatch line for workspace=$expected_workspace after push to $chat"
}

# --------------------------------------------------------------------
# Group A: configuration-layer multi-hop (yaml chain)
# --------------------------------------------------------------------

push_and_wait "${MOCK_FEISHU_PORT_DEV}"    "oc_pra_dev"        "ou_admin" "feishu_app_dev"    "ws_alpha"
push_and_wait "${MOCK_FEISHU_PORT_KANBAN}" "oc_pra_kanban"     "ou_admin" "feishu_app_kanban" "ws_bravo"
push_and_wait "${MOCK_FEISHU_PORT_DEV}"    "oc_pra_restricted" "ou_admin" "feishu_app_dev"    "ws_charlie"

# Pull the per-session dispatched-notification lines. Each session
# logs its own line; we filter by workspace= attribute to get the
# right one.
ALPHA_LINE=$(grep 'channel notification dispatched' "$LOG_PATH" | grep 'workspace="ws_alpha"' | head -1)
BRAVO_LINE=$(grep 'channel notification dispatched' "$LOG_PATH" | grep 'workspace="ws_bravo"' | head -1)
CHARLIE_LINE=$(grep 'channel notification dispatched' "$LOG_PATH" | grep 'workspace="ws_charlie"' | head -1)

[[ -n "$ALPHA_LINE"   ]] || _fail_with_context "A: no dispatch log for ws_alpha"
[[ -n "$BRAVO_LINE"   ]] || _fail_with_context "A: no dispatch log for ws_bravo"
[[ -n "$CHARLIE_LINE" ]] || _fail_with_context "A: no dispatch log for ws_charlie"

# A1: ws_alpha sees ws_bravo (declared next-hop)
assert_contains    "$ALPHA_LINE"   "$URI_BRAVO"   "A1: ws_alpha reaches ws_bravo"
# A2: ws_alpha does NOT see ws_charlie (transitive not applied — spec §6.4)
assert_not_contains "$ALPHA_LINE"  "$URI_CHARLIE" "A2: ws_alpha does NOT reach ws_charlie (1-hop only)"

# A3: ws_bravo sees ws_charlie (its own next-hop)
assert_contains    "$BRAVO_LINE"   "$URI_CHARLIE" "A3: ws_bravo reaches ws_charlie"
# A4: ws_bravo sees ws_alpha (reverse symmetric — alpha declared bravo)
assert_contains    "$BRAVO_LINE"   "$URI_ALPHA"   "A4: ws_bravo reaches ws_alpha (symmetric reverse)"

# A5: ws_charlie does NOT see ws_alpha (no two-hop transitive)
assert_not_contains "$CHARLIE_LINE" "$URI_ALPHA"  "A5: ws_charlie does NOT reach ws_alpha (transitive blocked)"

# --------------------------------------------------------------------
# Group B: runtime BGP propagation (same session, multiple inbounds
# with different sender_id → BGP learn grows reachable_set)
# --------------------------------------------------------------------

# Capture the existing learned-URIs lines BEFORE we push more inbounds,
# so we can isolate the "after push 2" diff. We push to ws_alpha which
# already has the baseline ou_admin learned from Group A.
LEARNED_BEFORE=0
if [[ -f "$LOG_PATH" ]]; then
  LEARNED_BEFORE=$( { grep 'learned URIs' "$LOG_PATH" 2>/dev/null || true; } | wc -l | tr -d ' \n')
  [[ -n "$LEARNED_BEFORE" ]] || LEARNED_BEFORE=0
fi

# B1 baseline: ou_admin's URI was already learned during Group A's
# alpha push. Verify it shows in any learned-URIs line.
LEARNED_LINES_INITIAL=$(grep 'learned URIs' "$LOG_PATH" || true)
assert_contains "$LEARNED_LINES_INITIAL" "esr://localhost/users/ou_admin" \
  "B1: BGP learn includes ou_admin user URI (from Group A inbound)"

# B2: push another inbound to oc_pra_dev with a DIFFERENT user
# (ou_visitor, never seen before in this session). The session for
# oc_pra_dev/feishu_app_dev was already created in Group A — this
# inbound delivers to the same session's pid, triggering another
# learn cycle.
push_and_wait "${MOCK_FEISHU_PORT_DEV}" "oc_pra_dev" "ou_visitor" "feishu_app_dev" "ws_alpha"

# Wait for the new learned-URIs line to land. Use grep -c diff so we
# don't false-positive on the Group A line.
for _ in $(seq 1 300); do
  count=0
  if [[ -f "$LOG_PATH" ]]; then
    count=$( { grep 'learned URIs' "$LOG_PATH" 2>/dev/null || true; } | wc -l | tr -d ' \n')
    [[ -n "$count" ]] || count=0
  fi
  if [[ "$count" -gt "$LEARNED_BEFORE" ]]; then break; fi
  sleep 0.1
done

# Pull the LATEST learned-URIs line (after the visitor push).
LEARNED_AFTER=$(grep 'learned URIs' "$LOG_PATH" | tail -1)
[[ -n "$LEARNED_AFTER" ]] || _fail_with_context "B: no learned-URIs log after visitor push"

# B2: visitor URI is in the new learn line.
assert_contains "$LEARNED_AFTER" "esr://localhost/users/ou_visitor" \
  "B2: BGP learn picks up new user (ou_visitor) on second inbound"

# B3: ou_admin is NOT in the new learn line (already known — idempotent).
assert_not_contains "$LEARNED_AFTER" "esr://localhost/users/ou_admin" \
  "B3: BGP learn does NOT re-emit ou_admin (idempotent set semantics)"

# --------------------------------------------------------------------
# Cleanup
# --------------------------------------------------------------------
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
  assert_actors_list_lacks "thread:${sid}" "cleanup: ${sid} torn down"
done

export _E2E_BASELINE="$BASELINE"
echo "PASS: scenario 05"
