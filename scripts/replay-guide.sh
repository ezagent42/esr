#!/usr/bin/env bash
# scripts/replay-guide.sh — replay a guide's chat-input/chat-output
# fences against a fresh esrd + mock_feishu fixture. See
# docs/superpowers/specs/2026-05-10-guide-driven-e2e.md §3.1.

set -Eeuo pipefail

GUIDE_PATH="${1:-}"
if [[ -z "${GUIDE_PATH}" || ! -f "${GUIDE_PATH}" ]]; then
  echo "usage: scripts/replay-guide.sh <guide-path>" >&2
  exit 64
fi

# --- bootstrap shared e2e helpers -----------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ESR_E2E_RUN_ID="replay-$(date +%s)-$$"

# shellcheck source=../tests/e2e/scenarios/common.sh
source "${REPO_ROOT}/tests/e2e/scenarios/common.sh"

# --- mapping table: logical user name -> synthetic open_id ----------
USER_MAP_JSON='{"linyilun":"ou_test_linyilun"}'
export USER_MAP_JSON

# --- _replay_diff: line-by-line diff with placeholder substitution ---
# $1 expected, $2 actual, $3 capture-var-name (optional).
#
# Captures are stored in a bash-3.2-compatible flat-list shape:
# `_CAPTURE_NAMES` holds the names, `_CAPTURE_VALUES` holds the
# parallel values. Lookups walk the names array (avoids `declare -A`
# which the system /bin/bash 3.2 on macOS doesn't support — common.sh
# itself follows the same constraint).
_CAPTURE_NAMES=()
_CAPTURE_VALUES=()

_capture_set() {
  local name="$1" value="$2" i
  for i in "${!_CAPTURE_NAMES[@]}"; do
    if [[ "${_CAPTURE_NAMES[$i]}" == "${name}" ]]; then
      _CAPTURE_VALUES[$i]="${value}"
      return 0
    fi
  done
  _CAPTURE_NAMES+=("${name}")
  _CAPTURE_VALUES+=("${value}")
}

_capture_get() {
  local name="$1" i
  for i in "${!_CAPTURE_NAMES[@]}"; do
    if [[ "${_CAPTURE_NAMES[$i]}" == "${name}" ]]; then
      printf '%s' "${_CAPTURE_VALUES[$i]}"
      return 0
    fi
  done
  return 1
}

_replay_diff() {
  local expected="$1" actual="$2" capture="${3:-}"
  local -a exp_lines act_lines
  # Bash-3.2 lacks `mapfile -t`; use a while-read loop.
  exp_lines=()
  while IFS= read -r _line; do exp_lines+=("$_line"); done <<<"${expected}"
  act_lines=()
  while IFS= read -r _line; do act_lines+=("$_line"); done <<<"${actual}"
  if [[ ${#exp_lines[@]} -ne ${#act_lines[@]} ]]; then
    echo "  line-count mismatch: expected ${#exp_lines[@]}, got ${#act_lines[@]}" >&2
    echo "  --- expected ---" >&2; echo "${expected}" >&2
    echo "  --- actual   ---" >&2; echo "${actual}" >&2
    return 1
  fi
  local k captured=""
  # Use variables for the replacement strings — bash-3.2's `${var//pat/repl}`
  # parser miscounts braces when `repl` contains `{n}` ERE quantifiers, so
  # an inline `[0-9a-f]{8}-...{12}}` replacement closes the expansion early.
  local _uuid_rx="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  local _int_rx="[0-9]+"
  local _ellipsis_rx=".*"
  for k in "${!exp_lines[@]}"; do
    local rx="${exp_lines[$k]}"
    # Escape regex specials in literal content BEFORE substituting placeholders.
    rx=$(printf '%s' "$rx" | sed -E 's/[][\/.^$*+?(){}|]/\\&/g')
    rx="${rx//<UUID>/$_uuid_rx}"
    rx="${rx//<int>/$_int_rx}"
    rx="${rx//<\\.\\.\\.>/$_ellipsis_rx}"
    if ! [[ "${act_lines[$k]}" =~ ^${rx}$ ]]; then
      echo "  line $((k+1)) mismatch:" >&2
      echo "    expected: ${exp_lines[$k]}" >&2
      echo "    actual:   ${act_lines[$k]}" >&2
      return 1
    fi
    if [[ -n "${capture}" && -z "${captured}" ]]; then
      if [[ "${exp_lines[$k]}" =~ \<UUID\>|\<int\> ]]; then
        local captured_val
        captured_val=$(echo "${act_lines[$k]}" | grep -oE '[0-9a-f-]{36}|[0-9]+' | head -1)
        _capture_set "${capture}" "${captured_val}"
        captured=1
      fi
    fi
  done
  return 0
}

# --- parse fences from the guide ------------------------------------
FENCES_JSON=$(uv run --project py python3 - "${GUIDE_PATH}" <<'PY'
import json, re, sys
guide = sys.argv[1]
text = open(guide, encoding="utf-8").read()
pat = re.compile(
    r"^```(chat-input|chat-output)([^\n]*)\n(.*?)\n```",
    re.MULTILINE | re.DOTALL,
)
out = []
for m in pat.finditer(text):
    kind = "input" if m.group(1) == "chat-input" else "output"
    attrs = {}
    for kv in m.group(2).strip().split():
        if "=" in kv:
            k, v = kv.split("=", 1)
            attrs[k] = v
    out.append({"kind": kind, "attrs": attrs, "body": m.group(3)})
print(json.dumps(out))
PY
)

N_FENCES=$(jq 'length' <<<"${FENCES_JSON}")
if [[ "${N_FENCES}" -eq 0 ]]; then
  echo "replay-guide: ${GUIDE_PATH} has no chat-* fences, skipping" >&2
  exit 0
fi

# --- bootstrap fixture ----------------------------------------------
# load_agent_yaml is omitted — slash-only smokes don't need an agent.
# seed_workspaces/seed_adapters mirror scenario 01's canonical preamble
# so the chat is workspace-bound and the FAA sidecar is spawned by
# Esr.Application.restore_adapters_from_disk/1 at boot.
seed_capabilities
seed_workspaces
seed_adapters
start_mock_feishu
start_esrd
wait_for_sidecar_ready 30

# Flat list of already-bound user names (bash-3.2: no `declare -A`).
_BOUND_USERS=()

_user_already_bound() {
  local name="$1" u
  for u in "${_BOUND_USERS[@]:-}"; do
    [[ "$u" == "$name" ]] && return 0
  done
  return 1
}

PASS_COUNT=0
FAIL_AT=""
LAST_SEEN=""

i=0
while [[ $i -lt $N_FENCES ]]; do
  IN_FENCE=$(jq -c ".[$i]" <<<"${FENCES_JSON}")
  IN_KIND=$(jq -r '.kind' <<<"${IN_FENCE}")
  if [[ "${IN_KIND}" != "input" ]]; then
    echo "replay-guide: ${GUIDE_PATH} fence #$i is ${IN_KIND}, expected input (alignment error)" >&2
    exit 65
  fi

  OUT_FENCE=$(jq -c ".[$((i+1))]" <<<"${FENCES_JSON}")
  OUT_KIND=$(jq -r '.kind' <<<"${OUT_FENCE}")
  if [[ "${OUT_KIND}" != "output" ]]; then
    echo "replay-guide: ${GUIDE_PATH} fence #$((i+1)) is ${OUT_KIND}, expected output (unpaired input)" >&2
    exit 65
  fi

  USER_NAME=$(jq -r '.attrs.user // "linyilun"' <<<"${IN_FENCE}")
  OPEN_ID=$(jq -r --arg n "${USER_NAME}" '.[$n] // empty' <<<"${USER_MAP_JSON}")
  if [[ -z "${OPEN_ID}" ]]; then
    echo "replay-guide: unknown user=${USER_NAME} (extend USER_MAP_JSON in scripts/replay-guide.sh)" >&2
    exit 66
  fi

  if ! _user_already_bound "${USER_NAME}"; then
    esr_cli admin submit user_add --arg name="${USER_NAME}" --wait --timeout 30 >/dev/null || true
    esr_cli admin submit feishu_bind \
      --arg name="${USER_NAME}" --arg feishu_user_id="${OPEN_ID}" \
      --wait --timeout 30 >/dev/null || true
    _BOUND_USERS+=("${USER_NAME}")
  fi

  APP_ID=$(jq -r '.attrs.app_id // "feishu_app_e2e-mock"' <<<"${IN_FENCE}")
  CHAT_ID=$(jq -r '.attrs.chat_id // "oc_mock_single"' <<<"${IN_FENCE}")
  BODY=$(jq -r '.body' <<<"${IN_FENCE}")
  # Substitute any captured placeholders ({{name}}) in the input body.
  # Bash-3.2: `${!arr[@]}` errors under `set -u` when the array is
  # empty, so gate on count.
  if [[ ${#_CAPTURE_NAMES[@]} -gt 0 ]]; then
    for _ci in "${!_CAPTURE_NAMES[@]}"; do
      _varname="${_CAPTURE_NAMES[$_ci]}"
      _value="${_CAPTURE_VALUES[$_ci]}"
      BODY="${BODY//\{\{${_varname}\}\}/${_value}}"
    done
  fi

  curl -sS -X POST "http://127.0.0.1:${MOCK_FEISHU_PORT}/push_inbound" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "${BODY}" --arg c "${CHAT_ID}" \
              --arg o "${OPEN_ID}" --arg a "${APP_ID}" \
              '{text:$t, chat_id:$c, user:$o, app_id:$a}')" \
    >/dev/null

  EXPECTED=$(jq -r '.body' <<<"${OUT_FENCE}")
  CAPTURE_VAR=$(jq -r '.attrs.capture // empty' <<<"${OUT_FENCE}")
  DEADLINE=$(( $(date +%s) + 30 ))
  REPLY=""
  while [[ $(date +%s) -lt $DEADLINE ]]; do
    # mock_feishu's GET /open-apis/im/v1/messages takes container_id (not chat_id).
    # `body.content` is a JSON-encoded `{"text":"..."}` string — unwrap with fromjson.
    LATEST=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/open-apis/im/v1/messages?container_id=${CHAT_ID}" \
             | jq -r '.data.items[0].body.content // empty | fromjson? | .text? // empty' 2>/dev/null || true)
    if [[ -n "${LATEST}" && "${LATEST}" != "${LAST_SEEN}" ]]; then
      REPLY="${LATEST}"; LAST_SEEN="${LATEST}"; break
    fi
    sleep 0.2
  done

  if [[ -z "${REPLY}" ]]; then
    FAIL_AT="step $((i/2 + 1)): no reply within 30s"
    break
  fi

  if ! _replay_diff "${EXPECTED}" "${REPLY}" "${CAPTURE_VAR}"; then
    FAIL_AT="step $((i/2 + 1)): output mismatch"
    break
  fi

  PASS_COUNT=$((PASS_COUNT + 1))
  i=$((i + 2))
done

if [[ -n "${FAIL_AT}" ]]; then
  echo "${GUIDE_PATH}: ${PASS_COUNT} step(s) passed, FAIL at ${FAIL_AT}"
  exit 1
fi

echo "${GUIDE_PATH}: ${PASS_COUNT} step(s) replayed, PASS"
exit 0
