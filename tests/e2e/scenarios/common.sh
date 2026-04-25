#!/usr/bin/env bash
# Shared preamble for PR-7 e2e scenarios. Sourced by 01/02/03.
# See docs/superpowers/specs/2026-04-23-pr7-e2e-feishu-to-cc-design.md §3.1.

set -Eeuo pipefail

# --- env bootstrap ---------------------------------------------------
: "${ESR_E2E_RUN_ID:=pr7-$(date +%s)-$$}"
: "${ESRD_INSTANCE:=e2e-${ESR_E2E_RUN_ID}}"
# T12-comms-3h: the CLI-side URL discovery (`esr actors list`,
# `cli:channel` bridge, etc.) reads `$ESR_INSTANCE`, not ESRD_INSTANCE.
# Keep the two aligned so every CLI run inside the scenario points at
# the same per-instance port file under ${ESRD_HOME}/${ESR_INSTANCE}.
: "${ESR_INSTANCE:=${ESRD_INSTANCE}}"
: "${ESRD_HOME:=/tmp/esrd-${ESR_E2E_RUN_ID}}"
: "${MOCK_FEISHU_PORT:=8201}"
: "${ESR_E2E_BARRIER_DIR:=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/barriers}"
: "${ESR_E2E_UPLOADS_DIR:=${ESRD_HOME}/default/uploads}"
: "${ESR_E2E_TMUX_SOCK:=/tmp/esr-e2e-${ESR_E2E_RUN_ID}/tmux.sock}"

# Principal identity used by `esr admin submit` (read by py/src/esr/cli/admin.py).
# Matches ou_admin seeded by seed_capabilities() with wildcard grants so
# register_adapter / new-session / end-session all pass the cap check.
: "${ESR_OPERATOR_PRINCIPAL_ID:=ou_admin}"

# PR-9 T11b.0a — first-boot capabilities fallback + ChannelChannel default.
# Esr.Capabilities.Supervisor seeds capabilities.yaml from this principal
# when the file is absent; EsrWeb.ChannelChannel uses it as the default
# principal_id on tool_invoke arriving before session_register. Held
# identical to ESR_OPERATOR_PRINCIPAL_ID so the same ou_admin row seeded by
# seed_capabilities covers Lane A + Lane B + cc_mcp tool_invoke paths.
: "${ESR_BOOTSTRAP_PRINCIPAL_ID:=${ESR_OPERATOR_PRINCIPAL_ID}}"

export ESR_E2E_RUN_ID ESRD_INSTANCE ESR_INSTANCE ESRD_HOME MOCK_FEISHU_PORT
export ESR_E2E_BARRIER_DIR ESR_E2E_UPLOADS_DIR ESR_E2E_TMUX_SOCK
export ESR_OPERATOR_PRINCIPAL_ID ESR_BOOTSTRAP_PRINCIPAL_ID

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
  # Idempotent teardown — safe to run twice.
  # `uv run` spawns python3 as a CHILD process; the pidfile captures the
  # uv wrapper's pid. Kill the wrapper first, then pkill any stray
  # mock_feishu python pinned to our port (E2E RCA: the wrapper+child
  # split meant wrapper died but python held :8201 forever).
  [[ -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid" ]] && {
    kill -9 "$(cat /tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid)" 2>/dev/null || true
    rm -f "/tmp/mock-feishu-${ESR_E2E_RUN_ID}.pid"
  }
  # Defensive: kill any python3 still bound to our mock_feishu port.
  # Scoped to our port number so a user's unrelated dev mock_feishu
  # (on a different port) stays untouched.
  pkill -9 -f "mock_feishu\.py --port ${MOCK_FEISHU_PORT}" 2>/dev/null || true
  rm -f /tmp/.sidecar.pid 2>/dev/null || true
  rm -f /tmp/esr-worker-*.pid 2>/dev/null || true
  if [[ -S "${ESR_E2E_TMUX_SOCK}" ]]; then
    tmux -S "${ESR_E2E_TMUX_SOCK}" kill-server 2>/dev/null || true
  fi
  # Preserve state dirs when debugging: ESR_E2E_KEEP_LOGS=1 leaves
  # ${ESRD_HOME} + barriers + mock-feishu files on disk.
  if [[ "${ESR_E2E_KEEP_LOGS:-0}" == "1" ]]; then
    echo "ESR_E2E_KEEP_LOGS=1 — preserving state at ${ESRD_HOME}" >&2
  else
    rm -rf "${ESRD_HOME}" "${ESR_E2E_BARRIER_DIR}" \
           "/tmp/mock-feishu-files-${MOCK_FEISHU_PORT}" 2>/dev/null || true
  fi

  # Best-effort esrd stop.
  ( cd "${_E2E_REPO_ROOT}" && \
    bash scripts/esrd.sh stop --instance="${ESRD_INSTANCE}" 2>/dev/null ) || true

  # T12-comms-3n (2026-04-25): kill the Python sidecars spawned by
  # WorkerSupervisor. `esrd.sh stop` sends SIGTERM to the BEAM but
  # scripts/spawn_worker.sh daemonises the sidecars, so they survive
  # and reconnect to mock_feishu in the next scenario — producing a
  # "stale handler responds to new session" race that flaked
  # `make e2e` (scenarios running back-to-back). Scoped to this
  # worktree's venv path so a user's dev sidecars stay untouched.
  pkill -9 -f "${_E2E_REPO_ROOT}/py/.venv.*feishu_adapter_runner" 2>/dev/null || true
  pkill -9 -f "${_E2E_REPO_ROOT}/py/.venv.*cc_adapter_runner" 2>/dev/null || true
  pkill -9 -f "${_E2E_REPO_ROOT}/py/.venv.*handler_worker" 2>/dev/null || true
  pkill -9 -f "${_E2E_REPO_ROOT}/adapters/cc_mcp/.venv.*esr_cc_mcp" 2>/dev/null || true

  # CI-only absolute cleanup (§7.2).
  if [[ "${ESR_E2E_CI:-0}" == "1" ]]; then
    rm -rf /tmp/esrd-e2e-* /tmp/esr-e2e-* /tmp/mock-feishu-files-* 2>/dev/null || true
    pkill -f "mock_feishu.py --port 82" 2>/dev/null || true
    pkill -f "erlexec.*esr" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
  fi
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
  # T12-comms-3e: FCP un-reacts on every CC reply (intended production
  # flow — the reaction signals "working", the un-react signals "done").
  # By the time this runs, ack has already landed → un-react has already
  # removed the reaction from /reactions (live list). To assert "CC did
  # react" we also count historical un-reactions.
  local message_id=$1 expected=$2
  local live historical total
  live=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/reactions" \
    | jq --arg mid "$message_id" '[.[] | select(.message_id==$mid)] | length')
  historical=$(curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/un_reactions" \
    | jq --arg mid "$message_id" '[.[] | select(.message_id==$mid)] | length')
  total=$((live + historical))
  assert_eq "$total" "$expected" "reactions-emitted (live+historical) for ${message_id}"
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
  # Write to the runtime's instance dir so Esr.Application.load_agents_from_disk/0
  # (called at boot when :restore_on_start is true) picks it up.
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
  cp "${_E2E_REPO_ROOT}/runtime/test/esr/fixtures/agents/simple.yaml" \
     "${ESRD_HOME}/${ESRD_INSTANCE}/agents.yaml"
}

seed_capabilities() {
  # Write the instance-scoped capabilities.yaml BEFORE esrd boots so the
  # FileLoader picks it up on first tick. ou_admin gets wildcard ["*"]
  # which satisfies adapter.register / session.create / session.end /
  # any other permission an e2e scenario will need. Matches the valid
  # fixture at runtime/test/support/capabilities_fixtures/valid.yaml.
  #
  # Two-path write (PR-9 T9 RCA):
  # - instance path (${ESRD_HOME}/${ESRD_INSTANCE}/capabilities.yaml):
  #   consumed by the Elixir admin dispatcher to authorize
  #   adapter.register / session.create etc.
  # - default path (${ESRD_HOME}/default/capabilities.yaml):
  #   consumed by the Python FeishuAdapter (_load_capabilities_checker
  #   at adapter.py:191) for Lane A msg.send gating. Without this file
  #   every inbound is denied with 你无权使用此 bot.
  #
  # ou_e2e is NOT granted workspace:e2e/msg.send — see TODO below.
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}" "${ESRD_HOME}/default"
  # Only ou_admin for v1 — feishu_adapter_runner's handler_hello declares
  # `permissions: []` (see esrd log), so `msg.send` isn't in the runtime
  # permissions registry. If we seed `workspace:e2e/msg.send` grants for
  # ou_e2e, the FileLoader rejects the ENTIRE yaml with
  # `{:unknown_permission, "msg.send", "ou_e2e"}` and keeps the previous
  # (empty) snapshot — which means ou_admin also loses its wildcard.
  # Workaround: stick with ou_admin only; scenarios use ou_admin as
  # sender (wildcard matches any workspace:*/msg.send).
  #
  # TODO: Once feishu_adapter_runner declares msg.send in handler_hello
  # (or msg.send is registered as a subsystem-intrinsic permission),
  # re-add the ou_e2e entries.
  local caps_yaml='principals:
  - id: ou_admin
    kind: feishu_user
    note: e2e admin (wildcard)
    capabilities: ["*"]'
  printf '%s\n' "$caps_yaml" > "${ESRD_HOME}/${ESRD_INSTANCE}/capabilities.yaml"
  printf '%s\n' "$caps_yaml" > "${ESRD_HOME}/default/capabilities.yaml"
}

seed_adapters() {
  # Boot-seed adapters.yaml so Esr.Application.restore_adapters_from_disk/1
  # spawns the feishu sidecar with the right base_url pointing at
  # mock_feishu. register_adapter via admin CLI would build a yaml
  # WITHOUT base_url (its arg schema doesn't accept it), leaving the
  # adapter to default to live lark_oapi — which fails silently in
  # the background. Seeding directly bypasses that gap.
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
  cat > "${ESRD_HOME}/${ESRD_INSTANCE}/adapters.yaml" <<EOF
instances:
  feishu_app_e2e-mock:
    type: feishu
    config:
      app_id: e2e-mock
      app_secret: mock
      base_url: http://127.0.0.1:${MOCK_FEISHU_PORT}
EOF
}

seed_workspaces() {
  # Write a minimal workspaces.yaml at default/ (Feishu adapter reads
  # ${ESRD_HOME}/default/workspaces.yaml regardless of ESR_INSTANCE —
  # see adapter.py:168). Maps the e2e chat_ids to a single "e2e"
  # workspace so the Feishu adapter's auth gate has something to
  # resolve against.
  #
  # Schema (py/src/esr/workspaces.py): chats is a list of
  # `{chat_id, app_id, kind}` dicts — raw strings crash the adapter at
  # `_load_workspace_map` (`.get` on str). PR-9 T9 e2e RCA.
  mkdir -p "${ESRD_HOME}/default"
  cat > "${ESRD_HOME}/default/workspaces.yaml" <<'EOF'
workspaces:
  e2e:
    cwd: "/tmp/esr-e2e-workspace"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_mock_single,       app_id: e2e-mock, kind: dm}
      - {chat_id: oc_mock_concurrent_a, app_id: e2e-mock, kind: dm}
      - {chat_id: oc_mock_concurrent_b, app_id: e2e-mock, kind: dm}
      - {chat_id: oc_mock_tmux,         app_id: e2e-mock, kind: dm}
    env: {}
EOF
}

start_esrd() {
  # Leaves ESR_E2E_TMUX_SOCK exported so application.ex's boot reader
  # picks it up (J1).
  ( cd "${_E2E_REPO_ROOT}" && \
    ESRD_HOME="${ESRD_HOME}" ESRD_INSTANCE="${ESRD_INSTANCE}" \
    ESR_E2E_TMUX_SOCK="${ESR_E2E_TMUX_SOCK}" \
    bash scripts/esrd.sh start --instance="${ESRD_INSTANCE}" )
}

wait_for_sidecar_ready() {
  # PR-9 T9: block until the feishu_adapter_runner subprocess has:
  #   (1) connected to Phoenix /adapter_hub/socket,
  #   (2) joined adapter:feishu/<id>,
  #   (3) pushed handler_hello,
  #   (4) opened its ws_connect to mock_feishu /ws.
  # Only once (4) happens does `self._ws_clients` on mock_feishu become
  # non-empty — earlier stages complete serially inside runner_core, so
  # ws_clients>=1 is a sufficient single-signal probe. Without this wait,
  # scenario 01 step 2 races the adapter startup and mock_feishu pushes
  # an empty-client-list inbound, which drops silently.
  local timeout_s=${1:-30} elapsed=0 count
  while true; do
    count=$(curl -sS --fail "http://127.0.0.1:${MOCK_FEISHU_PORT}/ws_clients" 2>/dev/null \
      | jq -r '.count // 0' 2>/dev/null || echo 0)
    if [[ "$count" -ge 1 ]]; then
      return 0
    fi
    sleep 0.2
    elapsed=$(awk "BEGIN {print $elapsed + 0.2}")
    if awk "BEGIN {exit !($elapsed > $timeout_s)}"; then
      _fail_with_context "wait_for_sidecar_ready: no /ws client after ${timeout_s}s (count=${count})"
      return 1
    fi
  done
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
