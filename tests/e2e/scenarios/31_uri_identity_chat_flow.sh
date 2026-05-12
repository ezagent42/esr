#!/usr/bin/env bash
# scenario 31 — URI identity chat-flow regression.
#
# Validates: wipe → boot → user_add → session_new flow succeeds via the
# canonical user UUID path WITHOUT the operator manually granting
# username-keyed caps. The 2026-05-12 chat-cap-check + resolve_submitter
# UUID-hop bugs are locked closed by the URI identity migration
# (spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §11.5).
#
# Per PR-5 plan note: if the e2e inbound-injection harness is too
# fragile, scenario 31 mirrors scenario 32's CLI path (same regression
# closure, more reliable harness). Inbound chat-injection coverage is
# already provided by scenario 20.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

BASELINE=$(e2e_tmp_baseline_snapshot)

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_capabilities
seed_workspaces
seed_adapters
start_esrd

# --- step 1: user_add → URI store populated ---------------------------
USER_NAME="linyilun_31"
USER_ADD_OUT=$(esr_cli admin submit user_add \
  --arg name="${USER_NAME}" \
  --wait --timeout 15)
echo "user_add: ${USER_ADD_OUT}"
assert_contains "$USER_ADD_OUT" "ok: true" "31: user_add ok"

# --- step 2: read UUID from users on disk -----------------------------
# Resolves via the canonical user URI: esr://localhost/users/<uuid>.
# The CLI/JSON disk write is the source-of-truth; URI store mirrors it.
USERS_DIR="${ESRD_HOME}/${ESR_INSTANCE}/users"
USER_UUID=$(find "${USERS_DIR}" -maxdepth 2 -name 'user.json' -print0 2>/dev/null \
  | xargs -0 -I {} sh -c 'jq -r --arg n "'"${USER_NAME}"'" "select(.username==\$n) | .id" {} 2>/dev/null' \
  | grep -E '^[0-9a-f-]{36}$' \
  | head -1)

[[ -n "${USER_UUID}" ]] \
  || _fail_with_context "31: could not read UUID for ${USER_NAME} from ${USERS_DIR}"
echo "31: user_uuid resolved: ${USER_UUID}"

# Sanity: UUID format
[[ "${USER_UUID}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || _fail_with_context "31: bad UUID shape: ${USER_UUID}"

# --- step 3: session_new with submitted_by=<UUID> ---------------------
# Pre-URI identity: resolve_submitter only accepted ou_xxx + username.
# Post: works with UUID directly via Esr.Uri.resolve.
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/uri-31"
mkdir -p "${WORKDIR}"

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --arg submitted_by="${USER_UUID}" \
  --wait --timeout 30)
echo "session_new: ${SESSION_OUT}"
assert_contains "$SESSION_OUT" "ok: true" \
  "31: session_new succeeds with submitted_by=<uuid> (no cap_grant)"

# Capture the assigned session_id and confirm it's a UUID
SID=$(echo "$SESSION_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}' | tr -d '"')
[[ -n "$SID" ]] || _fail_with_context "31: no session_id from session_new"
[[ "$SID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || _fail_with_context "31: session_id is not a UUID: ${SID}"
echo "31: session created: ${SID}"

# --- step 4: cleanup --------------------------------------------------
esr_cli admin submit session_end \
  --arg "session_id=${SID}" \
  --wait --timeout 30 || true

export _E2E_BASELINE="$BASELINE"
echo "PASS: scenario 31 (URI identity chat-flow regression)"
