#!/usr/bin/env bash
# Shared preamble for PR-7 e2e scenarios. Sourced by 01/02/03.
# See docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md §3.1.

set -Eeuo pipefail

# --- env bootstrap ---------------------------------------------------
: "${ESR_E2E_RUN_ID:=pr7-$(date +%s)-$$}"
: "${ESRD_INSTANCE:=e2e-${ESR_E2E_RUN_ID}}"
: "${ESRD_HOME:=/tmp/esrd-${ESR_E2E_RUN_ID}}"
: "${MOCK_FEISHU_PORT:=8201}"
: "${ESR_E2E_BARRIER_DIR:=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/barriers}"
: "${ESR_E2E_UPLOADS_DIR:=${ESRD_HOME}/default/uploads}"
: "${ESR_E2E_TMUX_SOCK:=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/tmux.sock}"

export ESR_E2E_RUN_ID ESRD_INSTANCE ESRD_HOME MOCK_FEISHU_PORT
export ESR_E2E_BARRIER_DIR ESR_E2E_UPLOADS_DIR ESR_E2E_TMUX_SOCK

mkdir -p "${ESR_E2E_BARRIER_DIR}" "${ESRD_HOME}" "$(dirname "${ESR_E2E_TMUX_SOCK}")"

# --- repo root (for paths inside helpers) ----------------------------
_E2E_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export _E2E_REPO_ROOT

# --- traps ------------------------------------------------------------
trap '_on_err $? $LINENO' ERR
trap '_on_exit' EXIT

_on_err() {
  local exit_code=$1 line=$2
  echo "FAIL: line ${line} exit ${exit_code} run_id=${ESR_E2E_RUN_ID}" >&2
  if [[ -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.log" ]]; then
    echo "--- mock_feishu.log tail ---" >&2
    tail -n 40 "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.log" >&2 || true
  fi
}

_on_exit() {
  # Idempotent teardown — safe to run twice.
  _e2e_teardown || true
}

_e2e_teardown() {
  # (full body in Task I; stub here — expanded when Makefile wiring lands)
  [[ -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid" ]] && {
    kill -9 "$(cat /tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid)" 2>/dev/null || true
    rm -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid"
  }
  rm -f /tmp/.sidecar.pid 2>/dev/null || true
  rm -f /tmp/esr-worker-*.pid 2>/dev/null || true
  if [[ -S "${ESR_E2E_TMUX_SOCK}" ]]; then
    tmux -S "${ESR_E2E_TMUX_SOCK}" kill-server 2>/dev/null || true
  fi
  rm -rf "${ESRD_HOME}" "${ESR_E2E_BARRIER_DIR}" \
         "/tmp/mock-feishu-files-${MOCK_FEISHU_PORT}" 2>/dev/null || true
}

# --- assertion helpers -----------------------------------------------
_fail_with_context() {
  echo "FAIL: $* run_id=${ESR_E2E_RUN_ID} line=${BASH_LINENO[0]}" >&2
  return 1
}

assert_eq() {
  local actual=$1 expected=$2 ctx=${3:-"assert_eq"}
  if [[ "$actual" != "$expected" ]]; then
    _fail_with_context "${ctx}: expected '${expected}' got '${actual}'"
    return 1
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 ctx=${3:-"assert_contains"}
  if [[ "$haystack" != *"$needle"* ]]; then
    _fail_with_context "${ctx}: '${needle}' not in '${haystack}'"
    return 1
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2 ctx=${3:-"assert_not_contains"}
  if [[ "$haystack" == *"$needle"* ]]; then
    _fail_with_context "${ctx}: unexpected '${needle}' in '${haystack}'"
    return 1
  fi
}

assert_ok() {
  local ctx=${E2E_ASSERT_CTX:-"assert_ok"}
  "$@" || _fail_with_context "${ctx}: command failed: $*"
}

assert_file_exists() {
  [[ -e "$1" ]] || _fail_with_context "assert_file_exists: missing $1"
}

assert_file_absent() {
  [[ ! -e "$1" ]] || _fail_with_context "assert_file_absent: unexpected $1"
}

# --- barrier primitives ----------------------------------------------
barrier_signal() {
  local name=$1
  touch "${ESR_E2E_BARRIER_DIR}/${name}"
}

barrier_wait() {
  local name=$1 timeout_s=${2:-30} elapsed=0
  while [[ ! -e "${ESR_E2E_BARRIER_DIR}/${name}" ]]; do
    sleep 0.2
    elapsed=$(awk "BEGIN {print $elapsed + 0.2}")
    if awk "BEGIN {exit !($elapsed > $timeout_s)}"; then
      _fail_with_context "barrier_wait: '${name}' timeout after ${timeout_s}s"
      return 1
    fi
  done
}

# --- mock-feishu assertion helpers -----------------------------------
assert_actors_list_has() {
  local substr=$1 ctx=${2:-"assert_actors_list_has"}
  local out
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  assert_contains "$out" "$substr" "${ctx} [actors list]"
}

assert_actors_list_lacks() {
  local substr=$1 ctx=${2:-"assert_actors_list_lacks"}
  local out
  out=$(uv run --project "${_E2E_REPO_ROOT}/py" esr actors list 2>&1 || true)
  assert_not_contains "$out" "$substr" "${ctx} [actors list]"
}

assert_mock_feishu_sent_includes() {
  local chat_id=$1 text_substr=$2
  curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
    | jq -e --arg cid "$chat_id" --arg txt "$text_substr" \
      '.[] | select(.receive_id==$cid) | .content | contains($txt)' >/dev/null \
    || _fail_with_context "expected mock_feishu.sent_messages for $chat_id to include '$text_substr'"
}

assert_mock_feishu_reactions_count() {
  local message_id=$1 expected=$2
  local count
  count=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/reactions" \
    | jq --arg mid "$message_id" '[.[] | select(.message_id==$mid)] | length')
  assert_eq "$count" "$expected" "reactions for ${message_id}"
}

assert_mock_feishu_file_sha() {
  local chat_id=$1 expected_sha=$2
  local actual
  actual=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_files" \
    | jq -r --arg cid "$chat_id" '.[] | select(.chat_id==$cid) | .sha256' \
    | head -n1)
  assert_eq "$actual" "$expected_sha" "sha256 of file sent to ${chat_id}"
}

assert_tmux_pane_contains() {
  local session=$1 substr=$2
  local pane_txt
  pane_txt=$(tmux -S "${ESR_E2E_TMUX_SOCK}" capture-pane -p -t "${session}" 2>&1)
  assert_contains "$pane_txt" "$substr" "tmux pane ${session}"
}

# --- baseline snapshot (knob c) --------------------------------------
e2e_tmp_baseline_snapshot() {
  # Deterministic hash of /tmp entries that could confuse cleanup
  # assertions — excludes the run's own paths.
  ls -1 /tmp 2>/dev/null \
    | grep -Ev "^(esrd-${ESR_E2E_RUN_ID}|esr-e2e-${ESR_E2E_RUN_ID}|mock-feishu-files-${MOCK_FEISHU_PORT}|mock-feishu-${ESR_E2E_RUN_ID}\\..*|\\.sidecar\\.pid|esr-worker-.*\\.pid)$" \
    | sort \
    | shasum -a 256 \
    | awk '{print $1}'
}

assert_baseline_clean() {
  local before=$1
  local after
  after=$(e2e_tmp_baseline_snapshot)
  assert_eq "$after" "$before" "/tmp baseline unchanged"
}

# --- one-shot setup helpers (bodies filled in by Tasks F/G/H/I) ------
start_mock_feishu() {
  local log="/tmp/mock-feishu-${ESR_E2E_RUN_ID}.log"
  local pidf="/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid"
  ( cd "${_E2E_REPO_ROOT}" && \
    uv run --project py python scripts/mock_feishu.py \
      --port "${MOCK_FEISHU_PORT}" > "$log" 2>&1 &
    echo $! > "$pidf" )
  # Readiness probe
  for _ in $(seq 1 50); do
    if curl -sSf "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  _fail_with_context "mock_feishu did not come up on port ${MOCK_FEISHU_PORT}"
}

load_agent_yaml() {
  mkdir -p "${ESRD_HOME}/default"
  cp "${_E2E_REPO_ROOT}/runtime/test/esr/fixtures/agents/simple.yaml" \
     "${ESRD_HOME}/default/agents.yaml"
}

start_esrd() {
  # Leaves ESR_E2E_TMUX_SOCK exported so application.ex's boot reader
  # picks it up (J1).
  ( cd "${_E2E_REPO_ROOT}" && \
    ESRD_HOME="${ESRD_HOME}" ESRD_INSTANCE="${ESRD_INSTANCE}" \
    ESR_E2E_TMUX_SOCK="${ESR_E2E_TMUX_SOCK}" \
    bash scripts/esrd.sh start --instance="${ESRD_INSTANCE}" )
}

register_feishu_adapter() {
  # Register an adapter record so `/new-session` can resolve the proxy
  # target. **Blocker fix 2 (v1.1):** prior version wrote
  # `${ESRD_HOME}/default/admin_queue/in/*.json` with an invented
  # envelope shape; real Watcher reads
  # `${ESRD_HOME}/${ESR_INSTANCE}/admin_queue/pending/<ulid>.yaml` and
  # the Dispatcher expects `{kind, args: {type, name, app_id,
  # app_secret}}` (see `runtime/lib/esr/admin/commands/register_adapter.ex`).
  # Use the real `esr admin submit` primitive instead of re-implementing
  # the atomic write dance — keeps us insulated from Watcher schema
  # changes and surfaces CLI-side bugs against the live code path.
  #
  # `app_secret=mock` is a deliberate placeholder: mock_feishu never
  # validates tenant_access_tokens, so any non-empty string works.
  # `base_url` is NOT a register_adapter arg — the adapter consumes
  # `AdapterConfig.base_url` from a separate path (see `adapters.yaml`
  # seeded by `load_agent_yaml()` or an `esr adapter add` call before
  # this helper). If a future test needs `base_url=http://127.0.0.1:…`
  # wired into the adapter config, add it via `esr adapter add` here
  # and drop this shell comment.
  ESR_INSTANCE="${ESRD_INSTANCE}" ESRD_HOME="${ESRD_HOME}" \
    uv run --project "${_E2E_REPO_ROOT}/py" esr admin submit register_adapter \
      --arg type=feishu \
      --arg name=feishu_app_e2e-mock \
      --arg app_id=e2e-mock \
      --arg app_secret=mock \
      --wait --timeout 10
}
