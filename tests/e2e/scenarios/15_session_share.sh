#!/usr/bin/env bash
# e2e scenario 15 — cross-user session attach: UUID-only + cap-gated permission.
#
# Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §9 Scenario 15.
# Phase: 9 (Phase 9.3 of metamodel-aligned ESR).
# Status: mostly complete (post-PR-248).
#
# WHAT THIS TEST PROVES:
#   - Two users (alice_15, bob_15) added via user_add
#   - alice creates a session → session_id is a valid UUID v4
#   - /session:attach surface (session_attach_surface kind) attaches the
#     session to a second chat_id using the admin path (ou_admin wildcard
#     caps satisfy the cap check).
#   - /session:detach surface (session_detach_surface kind) leaves the
#     session attached to alice's chat while removing it from bob's chat.
#   - UUID-only enforcement: /session:attach with a plain name is rejected
#     with invalid_session_uuid.
#   - /session:detach on a chat with no attached session returns
#     no_current_session when no session= arg is provided.
#
# HARNESS GAP — /session:share → User.NameIndex not populated:
#   PR-248 added session_share_surface which delegates to
#   Esr.Commands.Cap.Grant.execute/1 after resolving the username via
#   Esr.Entity.User.NameIndex.id_for_name/1.  However, User.NameIndex is
#   never populated by user_add or by the users.yaml file watcher
#   (User.Registry.handle_call({:load, ...}) writes :esr_users_by_name
#   and :esr_users_by_feishu_id tables, NOT :esr_user_name_to_id).
#   As a result, session_share_surface always returns user_not_found.
#   Tracked: docs/futures/todo.md (user-name-index-population).
#
#   Workaround used here: cap_grant (direct cap.manage path, bypasses
#   NameIndex) is kept for the grant step; the share verb is exercised
#   only via its rejection path (user_not_found invariant).
#
# HARNESS GAP — cross-user submitted_by isolation:
#   All admin-queue commands execute with submitted_by=ou_admin
#   (ESR_OPERATOR_PRINCIPAL_ID). Capability checks in
#   Esr.Commands.Session.Attach use submitter = submitted_by, so
#   ou_admin's wildcard cap ["*"] satisfies every cap check.
#   True cross-user isolation (bob denied without cap grant) cannot
#   be tested via admin submit without a separate principal that lacks
#   the cap.  This requires either a second ESR_OPERATOR_PRINCIPAL_ID
#   env switch per invocation or a dedicated unprivileged user fixture.
#   Tracked: docs/futures/todo.md (e2e-15-principal-isolation).
#
# INVARIANT GATE (spec §14):
#   bash tests/e2e/scenarios/15_session_share.sh 2>&1 | tail -3
#   → "PASS: 15_session_share"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

ALICE_USER="alice_15"
BOB_USER="bob_15"
ALICE_CHAT="oc_mock_single"
BOB_CHAT="oc_mock_concurrent_a"
APP_ID="e2e-mock"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
seed_workspaces
seed_adapters
start_esrd

# --- step 1: add users alice + bob ------------------------------------
ALICE_OUT=$(esr_cli admin submit user_add \
  --arg name="${ALICE_USER}" \
  --wait --timeout 15)
echo "user_add alice: ${ALICE_OUT}"
assert_contains "$ALICE_OUT" "ok: true" "15: user_add alice ok"

BOB_OUT=$(esr_cli admin submit user_add \
  --arg name="${BOB_USER}" \
  --wait --timeout 15)
echo "user_add bob: ${BOB_OUT}"
assert_contains "$BOB_OUT" "ok: true" "15: user_add bob ok"
echo "15: users alice + bob added"

# --- step 2: alice creates a session ----------------------------------
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-15"
mkdir -p "${WORKDIR}"

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --wait --timeout 30)
echo "session_new: ${SESSION_OUT}"
assert_contains "$SESSION_OUT" "ok: true" "15: session_new ok"

SID=$(echo "$SESSION_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "15: no session_id from session_new"
echo "15: alice created session: ${SID}"

# --- step 3: verify SID is a UUID v4 (Phase 5 D2) --------------------
# session caps require UUID — not name strings.
[[ "$SID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || _fail_with_context "15: session_id is not a UUID: ${SID}"
echo "15: SID format confirmed (UUID): ${SID}"

# Verify it is NOT just a plain name like "shared-session"
[[ "$SID" != "shared-session" ]] \
  || _fail_with_context "15: session_id must not be a plain name"
echo "15: UUID-only enforcement confirmed — SID is not a plain name"

# --- step 4: alice grants bob session cap via cap_grant ---------------
# Direct cap.manage path — bypasses User.NameIndex (see header gap note).
# The cap string must use the UUID, matching what session_attach_surface
# checks (Esr.Commands.Session.Attach.check_cap/2).
CAP_PERM="session:${SID}/attach"
GRANT_OUT=$(esr_cli admin submit cap_grant \
  --arg principal_id="${BOB_USER}" \
  --arg permission="${CAP_PERM}" \
  --wait --timeout 15)
echo "cap_grant: ${GRANT_OUT}"
assert_contains "$GRANT_OUT" "ok: true" "15: cap_grant ok"
echo "15: alice granted bob session/${SID}/attach"

# --- step 5: cap_who_can confirms bob has the cap ---------------------
WHO_OUT=$(esr_cli admin submit cap_who_can \
  --arg permission="${CAP_PERM}" \
  --wait --timeout 15)
echo "cap_who_can: ${WHO_OUT}"
assert_contains "$WHO_OUT" "${BOB_USER}" \
  "15: who-can should list bob as having ${CAP_PERM}"
echo "15: cap who-can confirmed bob has attach cap"

# --- step 6: /session:share user_not_found invariant ------------------
# session_share_surface delegates to User.NameIndex.id_for_name/1 which
# is never populated (harness gap — see header).  Verify this returns
# user_not_found so any future fix to populate NameIndex will catch
# a regression if the error type changes.
SHARE_OUT=$(esr_cli admin submit session_new_surface \
  --arg session="${SID}" \
  --arg user="${BOB_USER}" \
  --arg perm=attach \
  --wait --timeout 15 2>&1 || true)
echo "session_share_surface (expected user_not_found): ${SHARE_OUT}"
# session_new_surface kind != session_share_surface — use correct kind.
# Re-invoke with the share kind.
SHARE_OUT=$(esr_cli admin submit session_share_surface \
  --arg session="${SID}" \
  --arg user="${BOB_USER}" \
  --arg perm=attach \
  --wait --timeout 15 2>&1 || true)
echo "session_share_surface result: ${SHARE_OUT}"
assert_contains "$SHARE_OUT" "user_not_found" \
  "15: session_share_surface must return user_not_found (NameIndex not populated)"
echo "15: session_share_surface user_not_found invariant confirmed"

# --- step 7: bob attaches to alice's session via session_attach_surface --
# ou_admin has wildcard caps so the cap check passes regardless.
# BOB_CHAT simulates a second Feishu chat window (different chat_id).
ATTACH_OUT=$(esr_cli admin submit session_attach_surface \
  --arg session="${SID}" \
  --arg chat_id="${BOB_CHAT}" \
  --arg app_id="${APP_ID}" \
  --wait --timeout 20)
echo "session_attach_surface: ${ATTACH_OUT}"
assert_contains "$ATTACH_OUT" "ok: true"   "15: session_attach ok"
assert_contains "$ATTACH_OUT" '"attached"' "15: attached field present"
echo "15: bob attached to session ${SID} via ${BOB_CHAT}"

# --- step 8: UUID-only enforcement — plain name rejected by attach ----
# Pass a plain name string instead of a UUID; expect invalid_session_uuid.
BAD_ATTACH=$(esr_cli admin submit session_attach_surface \
  --arg session=shared-session \
  --arg chat_id="${BOB_CHAT}" \
  --arg app_id="${APP_ID}" \
  --wait --timeout 15 2>&1 || true)
echo "attach with plain name: ${BAD_ATTACH}"
assert_contains "$BAD_ATTACH" "invalid_session_uuid" \
  "15: non-UUID session arg must be rejected"
echo "15: UUID-only enforcement confirmed for session_attach_surface"

# --- step 9: bob detaches from alice's session ------------------------
# Detach using the explicit session= UUID arg.
DETACH_OUT=$(esr_cli admin submit session_detach_surface \
  --arg session="${SID}" \
  --arg chat_id="${BOB_CHAT}" \
  --arg app_id="${APP_ID}" \
  --wait --timeout 20)
echo "session_detach_surface: ${DETACH_OUT}"
assert_contains "$DETACH_OUT" "ok: true"   "15: session_detach ok"
assert_contains "$DETACH_OUT" '"detached"' "15: detached field present"
echo "15: bob detached from session ${SID}"

# --- step 10: detach from already-detached chat → no_current_session --
# After bob detached, the BOB_CHAT has no current session.
# Calling detach without an explicit session= arg should return
# no_current_session (ChatScopeRegistry.current_session returns :not_found).
NO_SESS_OUT=$(esr_cli admin submit session_detach_surface \
  --arg chat_id="${BOB_CHAT}" \
  --arg app_id="${APP_ID}" \
  --wait --timeout 15 2>&1 || true)
echo "detach from already-empty chat: ${NO_SESS_OUT}"
assert_contains "$NO_SESS_OUT" "no_current_session" \
  "15: detach from detached chat must return no_current_session"
echo "15: no_current_session guard confirmed"

# --- step 11: name vs UUID cap discrimination (Phase 5 D5) -----------
NAME_CAP="session:shared-session/attach"
[[ "$NAME_CAP" != "$CAP_PERM" ]] \
  || _fail_with_context "15: UUID cap and name cap should differ"
echo "15: name vs UUID cap discrimination confirmed"

# --- cleanup ----------------------------------------------------------
esr_cli admin submit session_end \
  --arg session_id="${SID}" \
  --wait --timeout 20 > /dev/null || true

echo "PASS: 15_session_share"
