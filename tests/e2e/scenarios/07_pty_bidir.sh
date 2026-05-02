#!/usr/bin/env bash
# scenario 07 — PTY ↔ cc_mcp bidirectional verification (no Feishu in
# the loop). Codifies the manual diagnostic procedure from PR-24's
# 2026-05-02 live-debug session: today's failure modes (lookup-key
# mismatch, dev-channels dialog hang, Phoenix.Channel JSON-mangled
# ESC bytes) all left this chain visibly broken; if this scenario
# stays green, the chain is intact.
#
# Flow:
#   1. Submit a session_new via the admin queue (bypasses Feishu).
#   2. Run tests/e2e/_helpers/dev_channels_unblock.sh to answer the
#      `--dangerously-load-development-channels` warning dialog so
#      cc_mcp boots and joins `cli:channel/<sid>`. (Operators normally
#      open /attach in a browser and answer it themselves; this helper
#      is e2e-only because the test runs unattended.)
#   3. Verify cc_mcp's session_register envelope arrived in the BEAM log.
#   4. Inject a `notification` envelope via the dev-only HTTP debug
#      endpoint (Direction 2: BEAM → claude). The injected text asks
#      claude to call the reply tool with a deterministic arg shape.
#   5. Verify a `tool_invoke` envelope arrived at `EsrWeb.ChannelChannel`
#      with the expected args (Direction 1: claude → BEAM).
#
# Requires: a running esrd-dev (default port 4001), admin queue under
# `$ESRD_HOME/<instance>/admin_queue/`, websocat on PATH, jq on PATH.

set -Eeuo pipefail

ESR_HOST="${ESR_PUBLIC_HOST:-127.0.0.1}"
ESR_PORT="${PORT:-4001}"
BASE_URL="http://${ESR_HOST}:${ESR_PORT}"
ESRD_HOME="${ESRD_HOME:-$HOME/.esrd-dev}"
ESRD_INSTANCE="${ESRD_INSTANCE:-default}"
QUEUE_DIR="${ESRD_HOME}/${ESRD_INSTANCE}/admin_queue"
LOG_FILE="${ESRD_HOME}/${ESRD_INSTANCE}/logs/launchd-stdout.log"

# Prefer the dev worktree the running esrd is running out of (set in
# the launchd plist as ESR_REPO_DIR), so this scenario can run against
# in-flight changes on a feature branch before they're merged back to
# the main repo's `scripts/` directory.
REPO_ROOT="${ESR_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
BOOTSTRAP="${REPO_ROOT}/tests/e2e/_helpers/dev_channels_unblock.sh"

for tool in websocat jq curl uv; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: required tool '$tool' not on PATH" >&2
    exit 2
  fi
done

if [[ ! -x "$BOOTSTRAP" ]]; then
  echo "FAIL: dev-channels-unblock helper not found or not executable at $BOOTSTRAP" >&2
  exit 2
fi

echo "[07_pty_bidir] esrd target: ${BASE_URL}, queue: ${QUEUE_DIR}"

# --- Step 1: submit session_new ---------------------------------------
admin_id=$(uv run python3 -c "import uuid; print(uuid.uuid4().hex[:26].upper())")
submitted_at=$(date -u +%Y-%m-%dT%H:%M:%S.000000+00:00)

mkdir -p "$QUEUE_DIR/pending" "$QUEUE_DIR/completed" "$QUEUE_DIR/failed"
# session dir must exist before esr-cc.sh tries to chdir into it
mkdir -p /tmp/scenario-07-pty-bidir
yaml_path="$QUEUE_DIR/pending/${admin_id}.yaml"

cat > "$yaml_path" <<EOF
id: ${admin_id}
kind: session_new
submitted_by: linyilun
submitted_at: "${submitted_at}"
args:
  agent: cc
  dir: /tmp/scenario-07-pty-bidir
  chat_id: scenario07_chat
  app_id: scenario07_app
EOF

echo "[07_pty_bidir] submitted admin_id=${admin_id}"

# Wait for the dispatcher to consume it.
deadline=$(( $(date +%s) + 20 ))
result_path=""
while (( $(date +%s) < deadline )); do
  if [[ -f "$QUEUE_DIR/completed/${admin_id}.yaml" ]]; then
    result_path="$QUEUE_DIR/completed/${admin_id}.yaml"
    break
  fi
  if [[ -f "$QUEUE_DIR/failed/${admin_id}.yaml" ]]; then
    echo "FAIL: admin command landed in failed/ — see $QUEUE_DIR/failed/${admin_id}.yaml" >&2
    cat "$QUEUE_DIR/failed/${admin_id}.yaml" >&2
    exit 1
  fi
  sleep 0.5
done

if [[ -z "$result_path" ]]; then
  echo "FAIL: admin command did not complete within 20s" >&2
  exit 1
fi

sid=$(grep -E "^[[:space:]]+session_id:" "$result_path" | awk '{print $2}')

if [[ -z "$sid" ]]; then
  echo "FAIL: could not extract session_id from $result_path" >&2
  cat "$result_path" >&2
  exit 1
fi

echo "[07_pty_bidir] session spawned sid=${sid}"

cleanup() {
  rc=$?
  echo "[07_pty_bidir] cleanup (exit ${rc})"
  rm -f "$yaml_path" "$result_path" 2>/dev/null || true
}
trap cleanup EXIT

# --- Step 2: bootstrap (answer dev-channels dialog) ------------------
# Give claude a moment to actually spawn its TUI before the bootstrap
# tries to answer the dialog; cc-bootstrap.sh has its own 4s sleep
# inside the WS session, but the WS itself can't open until the
# session's PtyProcess has registered with PeerRegistry. 2s here
# matches the gap we saw in PR-24 live-debug between admin-completed
# and the dialog rendering on stdout.
sleep 2
"$BOOTSTRAP" "$sid" >/dev/null 2>&1 || true

# --- Step 3: verify cc_mcp joined ------------------------------------
deadline=$(( $(date +%s) + 30 ))
joined=0
while (( $(date +%s) < deadline )); do
  if grep -q "JOINED cli:channel/${sid}" "$LOG_FILE" 2>/dev/null; then
    joined=1
    break
  fi
  sleep 0.5
done

if (( joined == 0 )); then
  echo "FAIL: cc_mcp did not join cli:channel/${sid} within 30s" >&2
  echo "--- last 40 lines of log relevant to ${sid} ---" >&2
  grep "${sid}" "$LOG_FILE" 2>/dev/null | tail -40 >&2 || true
  exit 1
fi

if ! grep -q "session_register.*${sid}" "$LOG_FILE"; then
  echo "FAIL: cc_mcp joined but did not send session_register envelope" >&2
  exit 1
fi

echo "[07_pty_bidir] cc_mcp joined + session_register confirmed"

# --- Step 4: inject notification (BEAM → claude) ---------------------
inject_text="please call mcp__esr-channel__reply with chat_id scenario07_chat and text scenario07-ack"
log_marker_pre=$(wc -c < "$LOG_FILE")

curl_resp=$(curl -sS -G \
  --data-urlencode "text=${inject_text}" \
  "${BASE_URL}/debug/inject_notification/${sid}")

if ! echo "$curl_resp" | jq -e '.ok == true' >/dev/null; then
  echo "FAIL: /debug/inject_notification did not return ok=true" >&2
  echo "$curl_resp" >&2
  exit 1
fi

echo "[07_pty_bidir] notification injected"

# --- Step 5: verify tool_invoke arrived (claude → BEAM) --------------
deadline=$(( $(date +%s) + 60 ))
seen_tool_invoke=0
# `scenario07_chat` is a unique marker we asked claude to echo back
# in the reply tool's `chat_id` arg — finding it on a `tool_invoke`
# line proves both that the inject went out and that claude routed a
# correctly-shaped reply call back through cc_mcp.
while (( $(date +%s) < deadline )); do
  if grep -F 'tool_invoke' "$LOG_FILE" | grep -qF 'scenario07_chat'; then
    seen_tool_invoke=1
    break
  fi
  sleep 1
done

if (( seen_tool_invoke == 0 )); then
  echo "FAIL: claude did not call mcp__esr-channel__reply within 60s" >&2
  echo "--- last tool_invoke lines (any session) ---" >&2
  grep -F 'tool_invoke' "$LOG_FILE" 2>/dev/null | tail -5 >&2 || true
  echo "--- log tail ---" >&2
  tail -40 "$LOG_FILE" >&2
  exit 1
fi

echo "[07_pty_bidir] OK — bidirectional PTY ↔ cc_mcp chain verified for sid=${sid}"
