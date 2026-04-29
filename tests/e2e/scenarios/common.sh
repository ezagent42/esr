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

  # PR-A T8 — extend teardown for the two-mock scenario 04 setup.
  # `uv run` spawns python3 as a CHILD; killing the uv wrapper leaves
  # the child python orphaned (still bound to port). Match the python
  # arg pattern directly to catch both uv wrapper AND its child.
  for _mock_suffix in dev kanban; do
    local _mpid="/tmp/mock-feishu-${ESR_E2E_RUN_ID}-${_mock_suffix}.pid"
    if [[ -f "${_mpid}" ]]; then
      kill -9 "$(cat "${_mpid}")" 2>/dev/null || true
      rm -f "${_mpid}"
    fi
  done
  pkill -9 -f "mock_feishu\.py --port ${MOCK_FEISHU_PORT_DEV:-8211}" 2>/dev/null || true
  pkill -9 -f "mock_feishu\.py --port ${MOCK_FEISHU_PORT_KANBAN:-8212}" 2>/dev/null || true
  # Belt-and-suspenders: any python that mentions mock_feishu in argv.
  # Scoped to mock_feishu.py so user's unrelated python procs survive.
  pkill -9 -f "python.*mock_feishu\.py" 2>/dev/null || true
  # Wait briefly for port release — TIME_WAIT can persist a few seconds.
  for _i in 1 2 3 4 5; do
    if ! lsof -i :"${MOCK_FEISHU_PORT_DEV:-8211}" -i :"${MOCK_FEISHU_PORT_KANBAN:-8212}" \
           >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
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
      _seed_e2e_chat_membership
      return 0
    fi
    sleep 0.1
  done
  _fail_with_context "mock_feishu did not come up on port ${MOCK_FEISHU_PORT}"
}

# PR-A T6/T7: the feishu adapter now sets `X-App-Id: <actor_id>` on
# every outbound POST to mock_feishu. T7's membership check rejects
# the request unless the (app_id, chat_id) pair has been registered.
# Pre-seed memberships for the e2e adapter ("feishu_app_e2e-mock")
# against every chat in seed_workspaces so scenarios 01-03 keep
# passing. Scenario 04 (multi-app) seeds its own memberships in
# start_two_mock_feishus.
_seed_e2e_chat_membership() {
  local chats=(
    oc_mock_single
    oc_mock_concurrent_a
    oc_mock_concurrent_b
    oc_mock_tmux
  )
  for chat in "${chats[@]}"; do
    curl -sS -X POST -H 'content-type: application/json' \
      -d "{\"app_id\":\"feishu_app_e2e-mock\",\"chat_id\":\"${chat}\"}" \
      "http://127.0.0.1:${MOCK_FEISHU_PORT}/register_membership" >/dev/null \
      || _fail_with_context "register_membership failed for ${chat}"
  done
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
  # Single path (post Lane-A drop, 2026-04-26):
  # - ${ESRD_HOME}/${ESRD_INSTANCE}/capabilities.yaml — sole consumer
  #   is the Elixir runtime (Lane B). Pre-PR drop-lane-a we also wrote
  #   ${ESRD_HOME}/default/capabilities.yaml for the Python adapter's
  #   Lane A `_load_capabilities_checker`; that path is dead now.
  #   See docs/notes/auth-lane-a-removal.md.
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
  local caps_yaml='principals:
  - id: ou_admin
    kind: feishu_user
    note: e2e admin (wildcard)
    capabilities: ["*"]'
  printf '%s\n' "$caps_yaml" > "${ESRD_HOME}/${ESRD_INSTANCE}/capabilities.yaml"
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
    root: "/tmp/esr-e2e-workspace"
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

# --- TIME_WAIT-friendly polling helper (RCA: 2026-04-26) ----------
# Wait until polling URL until jq filter matches OR deadline expires.
# Usage:
#   wait_for_url_jq_match URL JQ [iters=1200] [sleep_ms=100]
#
# Replaces the previous `for _ in $(seq 1 N); do curl ...; done` shape
# that opened a new TCP socket per iteration → ~1200 TIME_WAIT entries
# per failing wait loop → exhausted the workstation's 127.0.0.1
# ephemeral port pool during PR-A T9 development. The Python helper
# uses one requests.Session, so 1200 polls = 1 TCP connection.
#
# Returns 0 on match, non-zero on deadline. Matched JSON written to
# stdout (same shape callers used to capture from the old curl|jq
# pipeline).
wait_for_url_jq_match() {
  local url=$1 filter=$2
  local iters=${3:-1200} sleep_ms=${4:-100}
  uv run --project "${_E2E_REPO_ROOT}/py" python \
    "${_E2E_REPO_ROOT}/tests/e2e/scenarios/_wait_url.py" \
    "$url" "$filter" \
    --iterations "$iters" --sleep-ms "$sleep_ms"
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

# =====================================================================
# PR-A T8 — multi-app helpers (scenario 04)
# =====================================================================
# Scenario 04 spawns TWO mock_feishus (different ports) and TWO adapter
# sidecars (different instance_ids). The helpers below mirror the
# single-mock seed_*/start_mock_feishu helpers above but parameterized
# for the two-app case.
#
# Workspaces:
#   ws_dev    — chats: oc_pra_dev (member of feishu_app_dev),
#                       oc_pra_orphan (NOT a member of any app — drives
#                                      step 4 non-member rejection)
#   ws_kanban — chats: oc_pra_kanban (member of feishu_app_kanban)
#
# Principals:
#   ou_admin       — wildcard ["*"] (full access; happy paths)
#   ou_restricted  — workspace:ws_dev/msg.send only (forbidden test
#                    on cross-app reply to ws_kanban)

: "${MOCK_FEISHU_PORT_DEV:=8211}"
: "${MOCK_FEISHU_PORT_KANBAN:=8212}"
export MOCK_FEISHU_PORT_DEV MOCK_FEISHU_PORT_KANBAN

seed_two_apps_workspaces() {
  # Dual-write: Python adapter (Lane A) reads ${ESRD_HOME}/default/
  # workspaces.yaml; Elixir runtime (Lane B + FCP cross-app dispatch)
  # reads ${ESRD_HOME}/${ESR_INSTANCE}/workspaces.yaml. Same content
  # to both so single-app inbound auth (Lane A) and cross-app reply
  # workspace_for_chat lookup (Lane B FCP) both have the right map.
  # Post-PR-A's Lane-A removal will collapse this to instance/ only.
  mkdir -p "${ESRD_HOME}/default" "${ESRD_HOME}/${ESRD_INSTANCE}"
  local ws_yaml
  ws_yaml="$(cat <<'EOF'
workspaces:
  ws_dev:
    root: "/tmp/esr-e2e-workspace-dev"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_pra_dev,        app_id: feishu_app_dev,    kind: dm}
      - {chat_id: oc_pra_restricted, app_id: feishu_app_dev,    kind: dm}
      - {chat_id: oc_pra_orphan,     app_id: feishu_app_dev,    kind: dm}
    env: {}
  ws_kanban:
    root: "/tmp/esr-e2e-workspace-kanban"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_pra_kanban, app_id: feishu_app_kanban, kind: dm}
    env: {}
EOF
)"
  printf '%s\n' "$ws_yaml" > "${ESRD_HOME}/default/workspaces.yaml"
  printf '%s\n' "$ws_yaml" > "${ESRD_HOME}/${ESRD_INSTANCE}/workspaces.yaml"
}

seed_two_capabilities() {
  # ou_admin: wildcard. ou_restricted: ws_dev only (not ws_kanban).
  # Single instance/ path post-Lane-A drop (2026-04-26). The
  # `workspace:ws_dev/*` shape uses a segment wildcard so the
  # FileLoader accepts the entry without `msg.send` being declared
  # in the runtime permissions registry — see file_loader.ex:119
  # (`validate_perm("*", _) -> :ok`) and grants.ex:39
  # (`segment_match?("*", _) -> true`). Substantively the same
  # grant as `workspace:ws_dev/msg.send` for FCP's runtime check.
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
  local caps_yaml='principals:
  - id: ou_admin
    kind: feishu_user
    note: e2e admin (wildcard)
    capabilities: ["*"]
  - id: ou_restricted
    kind: feishu_user
    note: e2e principal allowed only for ws_dev
    capabilities:
      - workspace:ws_dev/*'
  printf '%s\n' "$caps_yaml" > "${ESRD_HOME}/${ESRD_INSTANCE}/capabilities.yaml"
}

seed_two_adapters() {
  mkdir -p "${ESRD_HOME}/${ESRD_INSTANCE}"
  cat > "${ESRD_HOME}/${ESRD_INSTANCE}/adapters.yaml" <<EOF
instances:
  feishu_app_dev:
    type: feishu
    config:
      app_id: feishu_app_dev
      app_secret: mock
      base_url: http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}
  feishu_app_kanban:
    type: feishu
    config:
      app_id: feishu_app_kanban
      app_secret: mock
      base_url: http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}
EOF
}

start_two_mock_feishus() {
  _start_one_mock "${MOCK_FEISHU_PORT_DEV}"    "dev"
  # Small gap to serialize uv venv access — two parallel uv runs can
  # race on lock files. _start_one_mock's wait loop ensures the dev
  # mock is already responding before kicking off kanban.
  _start_one_mock "${MOCK_FEISHU_PORT_KANBAN}" "kanban"
  # Pre-register memberships. feishu_app_dev is a member of oc_pra_dev
  # but NOT oc_pra_orphan (that's the step-4 non-member trigger).
  # feishu_app_kanban is only a member of oc_pra_kanban.
  for chat in oc_pra_dev oc_pra_restricted; do
    curl -sS --connect-timeout 1 --max-time 5 \
      -X POST -H 'content-type: application/json' \
      -d "{\"app_id\":\"feishu_app_dev\",\"chat_id\":\"${chat}\"}" \
      "http://127.0.0.1:${MOCK_FEISHU_PORT_DEV}/register_membership" >/dev/null \
      || _fail_with_context "register_membership feishu_app_dev/${chat} failed"
  done
  curl -sS --connect-timeout 1 --max-time 5 \
    -X POST -H 'content-type: application/json' \
    -d '{"app_id":"feishu_app_kanban","chat_id":"oc_pra_kanban"}' \
    "http://127.0.0.1:${MOCK_FEISHU_PORT_KANBAN}/register_membership" >/dev/null \
    || _fail_with_context "register_membership feishu_app_kanban/oc_pra_kanban failed"
}

_start_one_mock() {
  local port=$1 suffix=$2
  local pidfile="/tmp/mock-feishu-${ESR_E2E_RUN_ID}-${suffix}.pid"
  local log="/tmp/mock-feishu-${ESR_E2E_RUN_ID}-${suffix}.log"
  ( cd "${_E2E_REPO_ROOT}" && \
    uv run --project py python scripts/mock_feishu.py --port "${port}" \
      > "${log}" 2>&1 &
    echo $! > "${pidfile}" )
  # 100 iterations × 0.2s = 20s — uv first-run venv sync can take 10+s.
  # `--connect-timeout 1 --max-time 2` keeps each iteration bounded so
  # connection-refused bounces fast and we don't burn 5 min on the
  # default curl timeout.
  for _ in $(seq 1 100); do
    if curl -sSf --connect-timeout 1 --max-time 2 \
            "http://127.0.0.1:${port}/sent_messages" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  _fail_with_context "mock_feishu (${suffix}) did not come up on port ${port}"
}

wait_for_two_sidecars_ready() {
  local timeout_s=${1:-30}
  for port in "${MOCK_FEISHU_PORT_DEV}" "${MOCK_FEISHU_PORT_KANBAN}"; do
    local deadline=$(($(date +%s) + timeout_s))
    while true; do
      # `--connect-timeout 1 --max-time 2` keeps each iteration fast
      # so the deadline check actually fires; without these, curl's
      # internal timeout (~5 min) blows past any reasonable timeout.
      local count
      count=$(curl -sS --fail --connect-timeout 1 --max-time 2 \
              "http://127.0.0.1:${port}/ws_clients" 2>/dev/null \
        | jq -r '.count // 0' 2>/dev/null || echo 0)
      [[ "$count" -ge 1 ]] && break
      if (( $(date +%s) > deadline )); then
        _fail_with_context "wait_for_two_sidecars_ready: port=${port} no /ws client after ${timeout_s}s"
      fi
      sleep 0.2
    done
  done
}
