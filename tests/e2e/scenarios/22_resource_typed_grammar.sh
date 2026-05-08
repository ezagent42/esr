#!/usr/bin/env bash
# e2e scenario 22 — resource-typed slash grammar end-to-end.
#
# Spec: docs/superpowers/specs/2026-05-08-resource-typed-grammar.md
#
# WHAT THIS TEST PROVES (spec invariants I1-I5):
#   - I1: Per-agent verbs live under /agent:* (covered by /agent:add +
#         /agent:list paths used here).
#   - I2: /pty:list enumerates PTY actor ids; /pty:attach (core) +
#         /claude_code:tui (claude_code plugin) emit TUI URLs.
#   - I3: /agent:list (no args) returns INSTANCES (not types);
#         /plugin:agent-types returns the type catalog.
#   - I4: /session:add-agent kind dispatch returns unknown_kind — the
#         text-dispatch deprecated-slash hint ("renamed; use /agent:add")
#         fires only via Feishu inbound text, NOT via the admin queue
#         path the harness uses; the unit test
#         test/esr/entity/slash_handler_dispatch_test.exs covers the
#         hint path.
#   - I5: /claude_code:tui registered via claude_code plugin
#         slash_routes block (rev-3 plugin-scoped command registration).
#
# Phase A.4 multi-agent isolation regression: with 2 agents in one
# session, /pty:list returns 2 distinct pty_actor_ids, and the URLs
# claude_code:tui emits for alice vs bob differ — the M-2 latent bug
# (PtyProcess pubsub topic keyed on session_id, aliasing siblings) is
# fixed when each PtyProcess registers under "pty:<actor_id>".
#
# COMPLEMENTS scenario 14 (multi-agent metadata), 18 (multi-instance
# spawn pipeline), 19 (session-first default).
#
# INVARIANT GATE (spec §11):
#   bash tests/e2e/scenarios/22_resource_typed_grammar.sh 2>&1 | tail -3
#   → "PASS: 22_resource_typed_grammar"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
seed_workspaces
seed_adapters
start_esrd

USERNAME="grammar_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"

esr_cli admin submit user_add --arg name="${USERNAME}" --wait --timeout 30 >/dev/null

# A synthetic chat context for chat-bound commands (chat_id+app_id are
# normally injected from the Feishu envelope; admin queue submits don't
# carry one, so we pass them as args explicitly to drive the lookup
# path of /agent:list, /pty:list, /claude_code:tui via the queue).
CHAT_ID="oc_e2e22_${ESR_E2E_RUN_ID}"
APP_ID="esr_e2e22_${ESR_E2E_RUN_ID}"

# --- step 1: spawn a session bound to the synthetic chat -------------
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-22"
mkdir -p "${WORKDIR}"

SESS_OUT=$(esr_cli admin submit session_new \
  --arg dir="${WORKDIR}" \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

SID=$(echo "$SESS_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "22: no session_id"
echo "22: session created: ${SID} (bound to chat ${CHAT_ID})"

# Add alice via /agent:add (was /session:add-agent in rev-2; renamed
# per Phase C of the resource-typed grammar refactor).
ADD_OUT=$(esr_cli admin submit agent_add \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=alice \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 agent_add: ${ADD_OUT}"
assert_contains "$ADD_OUT" "ok: true" "22: /agent:add ok"
assert_contains "$ADD_OUT" "alice"    "22: /agent:add returns alice name"
assert_contains "$ADD_OUT" "actor_ids" "22: /agent:add returns actor_ids"

# --- step 2: /agent:list returns INSTANCES (I3) ----------------------
LIST_OUT=$(esr_cli admin submit agent_list \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 agent_list (instances): ${LIST_OUT}"
assert_contains "$LIST_OUT" "alice" "22: /agent:list lists alice INSTANCE"
assert_not_contains "$LIST_OUT" "available agent types" "22: /agent:list NOT type catalog"

# --- step 3: /plugin:agent-types returns TYPE CATALOG (I3) -----------
TYPES_OUT=$(esr_cli admin submit plugin_agent_types --wait --timeout 30)
echo "22 plugin_agent_types: ${TYPES_OUT}"
assert_contains "$TYPES_OUT" "available agent types" "22: /plugin:agent-types returns type catalog"
assert_contains "$TYPES_OUT" "cc"                    "22: includes cc type"

# --- step 4: /pty:list returns the spawned PTY (I2) ------------------
PTY_LIST_OUT=$(esr_cli admin submit pty_list \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 pty_list: ${PTY_LIST_OUT}"
assert_contains "$PTY_LIST_OUT" "alice"        "22: /pty:list shows alice"
assert_contains "$PTY_LIST_OUT" "pty_actor_id" "22: /pty:list emits pty_actor_id field"

# Capture alice's pty actor_id (UUID v4) — render is JSON-ish:
# `ptys: [{..."pty_actor_id":"<uuid>"...}]`.
PTY_ID_ALICE=$(echo "$PTY_LIST_OUT" \
  | grep -oE '"pty_actor_id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"' \
  | head -1 \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
[[ -n "$PTY_ID_ALICE" ]] || _fail_with_context "22: no pty_actor_id from /pty:list"
echo "22: alice pty_actor_id = ${PTY_ID_ALICE}"

# --- step 5: /pty:attach pty=<id> returns URL (I2) -------------------
ATTACH_OUT=$(esr_cli admin submit pty_attach \
  --arg pty="${PTY_ID_ALICE}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 pty_attach: ${ATTACH_OUT}"
assert_contains "$ATTACH_OUT" "${PTY_ID_ALICE}" "22: /pty:attach URL contains pty id"
assert_contains "$ATTACH_OUT" "/sessions"       "22: /pty:attach URL has expected shape"

# --- step 6: /claude_code:tui (plugin command) ------------------------
# I2 + I5: plugin-registered slash uses Phase A's pty_actor_id_for/2
# to resolve agent name → PTY id, then delegates to /pty:attach.
# Proves I5: claude_code plugin registered the /claude_code:tui slash
# via its manifest's slash_routes block (rev-3 plugin-scoped command
# registration mechanism). A missing manifest entry would surface
# here as `unknown_kind`.
TUI_OUT=$(esr_cli admin submit claude_code_tui \
  --arg name=alice \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 claude_code_tui: ${TUI_OUT}"
assert_not_contains "$TUI_OUT" "unknown_kind" "22: I5: /claude_code:tui kind registered via plugin manifest"
assert_contains "$TUI_OUT" "${PTY_ID_ALICE}" "22: /claude_code:tui resolves alice → same PTY id as /pty:list"
assert_contains "$TUI_OUT" "/sessions"        "22: /claude_code:tui emits a /sessions URL"

# --- step 6b: multi-agent PTY isolation (Phase A.4 latent-bug fix) ---
# Add a second agent (bob), confirm /pty:list returns 2 distinct
# pty_actor_ids and /pty:attach emits a different URL for bob's id.
# Spec rev-4 §4.5: each PtyProcess registers under "pty:<actor_id>",
# so multi-agent sessions no longer alias.
ADD2_OUT=$(esr_cli admin submit agent_add \
  --arg session_id="${SID}" \
  --arg type=cc \
  --arg name=bob \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
assert_contains "$ADD2_OUT" "ok: true" "22: second /agent:add ok"

PTY_LIST2_OUT=$(esr_cli admin submit pty_list \
  --arg chat_id="${CHAT_ID}" \
  --arg app_id="${APP_ID}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 pty_list (2 agents): ${PTY_LIST2_OUT}"
assert_contains "$PTY_LIST2_OUT" "alice" "22: /pty:list still shows alice"
assert_contains "$PTY_LIST2_OUT" "bob"   "22: /pty:list now shows bob"

# Extract both pty_actor_ids; assert they differ (Phase A.4 invariant —
# pre-fix both PtyProcesses would have aliased on session_id-keyed pubsub).
PTY_IDS=$(echo "$PTY_LIST2_OUT" \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
  | sort -u)
PTY_COUNT=$(echo "$PTY_IDS" | wc -l | tr -d ' ')
echo "22: distinct pty_actor_ids in 2-agent session = ${PTY_COUNT}"
[[ "$PTY_COUNT" -ge 2 ]] || _fail_with_context "22: Phase A.4 regression — bob's PTY aliases alice's (count=${PTY_COUNT})"

# Pull bob's id specifically (the one that's not alice's), feed it to
# /pty:attach and assert the URL differs from alice's.
PTY_ID_BOB=$(echo "$PTY_IDS" | grep -v "$PTY_ID_ALICE" | head -1)
[[ -n "$PTY_ID_BOB" ]] || _fail_with_context "22: could not isolate bob's pty_actor_id"
echo "22: bob pty_actor_id = ${PTY_ID_BOB}"

ATTACH_BOB_OUT=$(esr_cli admin submit pty_attach \
  --arg pty="${PTY_ID_BOB}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)
echo "22 pty_attach bob: ${ATTACH_BOB_OUT}"
assert_contains "$ATTACH_BOB_OUT" "${PTY_ID_BOB}" "22: bob's /pty:attach URL contains bob's pty id"
# bob's URL MUST NOT contain alice's pty id — same session, distinct
# pty_actor_id (Phase A.4 invariant).
if echo "$ATTACH_BOB_OUT" | grep -q "${PTY_ID_ALICE}"; then
  _fail_with_context "22: bob's /pty:attach URL contains alice's pty id — Phase A.4 regression"
fi

# --- step 7: I4 — session_add_agent kind dispatch via admin queue ----
# Admin queue dispatches by kind, not slash text — the deprecated_slashes
# hint (which says "renamed; use /agent:add") fires only on Feishu
# inbound text dispatch. Through the queue, the kind `session_add_agent`
# is gone, so dispatch returns unknown_kind. This is the operator-
# visible signal via the admin path.
DEPR_OUT=$(esr_cli admin submit session_add_agent \
  --arg type=cc \
  --arg name=ghost \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 20 2>&1 || true)
echo "22 deprecated session_add_agent kind: ${DEPR_OUT}"
assert_contains "$DEPR_OUT" "unknown_kind" \
  "22: I4: legacy session_add_agent kind no longer registered (renamed to agent_add)"

# --- final ------------------------------------------------------------
echo "PASS: 22_resource_typed_grammar"
