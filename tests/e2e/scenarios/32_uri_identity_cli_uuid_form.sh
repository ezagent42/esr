#!/usr/bin/env bash
# scenario 32 — URI identity CLI submitted_by=<uuid> form.
#
# Pre-URI-identity: Esr.Commands.Workspace.Resolve.resolve_submitter/1
# only recognized `submitter_username=X` and `submitted_by=ou_xxx`
# (feishu open_id). Submitting `submitted_by=<UUID>` returned
# :no_workspace_target — see docs/futures/todo.md row
# `resolve-submitter-format-agnostic` (closed by PR-5).
#
# Post: Esr.Uri.resolve("esr://localhost/users/<uuid>") returns the
# canonical user URI directly. The submitter resolution accepts UUIDs
# uniformly with usernames and ou_xxx ids.
#
# Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §11.3+§11.5

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

# --- step 1: user_add ------------------------------------------------
USER_NAME="linyilun_32"
USER_ADD_OUT=$(esr_cli admin submit user_add \
  --arg name="${USER_NAME}" \
  --wait --timeout 15)
echo "user_add: ${USER_ADD_OUT}"
assert_contains "$USER_ADD_OUT" "ok: true" "32: user_add ok"

# --- step 2: read UUID directly from disk ----------------------------
USERS_DIR="${ESRD_HOME}/${ESR_INSTANCE}/users"
USER_UUID=$(find "${USERS_DIR}" -maxdepth 2 -name 'user.json' -print0 2>/dev/null \
  | xargs -0 -I {} sh -c 'jq -r --arg n "'"${USER_NAME}"'" "select(.username==\$n) | .id" {} 2>/dev/null' \
  | grep -E '^[0-9a-f-]{36}$' \
  | head -1)

[[ -n "${USER_UUID}" ]] \
  || _fail_with_context "32: could not read UUID for ${USER_NAME}"
echo "32: user_uuid: ${USER_UUID}"

# --- step 3: CLI session_new with submitted_by=<UUID> ----------------
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/uri-32"
mkdir -p "${WORKDIR}"

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --arg submitted_by="${USER_UUID}" \
  --wait --timeout 30)
echo "session_new: ${SESSION_OUT}"

# The core regression assertion: UUID-form submitted_by works.
assert_contains "$SESSION_OUT" "ok: true" \
  "32: CLI submitted_by=<uuid> resolves successfully"
assert_not_contains "$SESSION_OUT" "no_workspace_target" \
  "32: no :no_workspace_target — UUID hop resolved"

SID=$(echo "$SESSION_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}' | tr -d '"')
[[ -n "$SID" ]] || _fail_with_context "32: no session_id from session_new"
echo "32: session_id=${SID}"

# --- step 4: cleanup --------------------------------------------------
esr_cli admin submit session_end \
  --arg "session_id=${SID}" \
  --wait --timeout 30 || true

export _E2E_BASELINE="$BASELINE"
echo "PASS: scenario 32 (URI identity CLI UUID submitted_by form)"
