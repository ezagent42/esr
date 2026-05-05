#!/usr/bin/env bash
# External verdict (spec §4.1, §4.1.1, §8). Authored by the user/Claude before
# loop launch; SHA-pinned in scripts/final_gate.sh.sha256; loop is forbidden
# to modify (LG-4).
#
# v2 (ESR v0.2 channel design, spec §§7.3, 8).
#   Single unified gate: 13 checks total.
#   Checks 1-6  : static + mock-scenario gate (loop-runnable, was v1 --mock).
#   Checks 7-13 : live-style L0..L6 MCP channel round-trip (was v1 --live).
#
#   Default (no args)  : mock_feishu + real esrd + real CC + real MCP.
#                        Requires no ~/.esr/live.env. Posts to mock_feishu.
#   --lark             : same 13 checks, but L1/L2/L6 post via the REAL Lark
#                        API. Requires ~/.esr/live.env (FEISHU_APP_ID,
#                        FEISHU_APP_SECRET, FEISHU_TEST_CHAT_ID).
#
#   The 7 L* artifacts (L0..L6) are identical across modes; only the
#   message-sender shim (lark_post / lark_find_bot_reply) flips between
#   mock_feishu's HTTP API and the real Lark Open API.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

mode="mock"
case "${1:-}" in
  "")        mode="mock" ;;
  --lark)    mode="lark" ;;
  --mock)    mode="mock" ;;  # accepted as explicit synonym of default
  -h|--help) echo "usage: $0 [--lark]"; exit 0 ;;
  *)         echo "usage: $0 [--lark]" >&2; exit 2 ;;
esac

fail=0
ts=$(date +%s)
section() { echo; echo "=== $* ==="; }

# ===========================================================================
# Checks 1-6 : static + mock-scenario gate (was v1 --mock block).
# ===========================================================================

section "1/13 make test"
if ! make test >/tmp/fg.test.log 2>&1; then
  echo "FAIL"; tail -40 /tmp/fg.test.log; fail=1
fi

section "2/13 verify_prd_matrix.py"
if ! uv run --project py python scripts/verify_prd_matrix.py >/tmp/fg.matrix.log 2>&1; then
  echo "FAIL"; cat /tmp/fg.matrix.log; fail=1
fi

section "3/13 loopguard (SHA-pin: final_gate.sh + loopguard-bundle)"
if ! bash scripts/loopguard.sh >/tmp/fg.lg.log 2>&1; then
  echo "FAIL"; tail -20 /tmp/fg.lg.log; fail=1
fi

section "4/13 plugin core-only boot e2e (replaces fossil scenario yamls)"
# 2026-05-06: was `esr scenario run e2e-esr-channel` against
# scenarios/e2e-esr-channel.yaml — that yaml's primary verbs were
# all P3-13-dead (`esr cmd run/stop/drain feishu-thread-session`),
# so it had been silently producing fail=1 without breaking the
# gate (since `if !` only sets a marker, not exit). Replaced with
# the modern `tests/e2e/scenarios/08_plugin_core_only.sh` which
# exercises the slash-command pipeline end-to-end (CommandQueue
# Watcher → Dispatcher → SlashRoute.Registry → /help, /plugin
# list) on a clean core-only boot — the load-bearing assertion
# that catches structural regressions in plugin loader / yaml
# parsing / boot supervision.
if ! bash tests/e2e/scenarios/08_plugin_core_only.sh >/tmp/fg.scn.log 2>&1; then
  echo "FAIL"; tail -20 /tmp/fg.scn.log; fail=1
fi

section "5/13 ledger integrity"
if ! uv run --project py python scripts/verify_ledger_append_only.py >/tmp/fg.led.log 2>&1; then
  echo "FAIL"; cat /tmp/fg.led.log; fail=1
fi

section "6/13 PRD acceptance manifest"
if ! uv run --project py python scripts/verify_prd_acceptance.py \
    --manifest docs/superpowers/prds/acceptance-manifest.yaml >/tmp/fg.acc.log 2>&1; then
  echo "FAIL"; cat /tmp/fg.acc.log; fail=1
fi

section "6b/13 no BLOCKED in ledger"
if grep -qE '<promise>BLOCKED:' docs/ralph-loop-ledger.md 2>/dev/null; then
  echo "FAIL — BLOCKED record in ledger"; fail=1
fi

if [[ $fail -ne 0 ]]; then
  echo
  echo "FINAL GATE v2 FAILED — mode=$mode (checks 1-6 did not pass)"
  exit 1
fi

# ===========================================================================
# Checks 7-13 : L0..L6 MCP channel round-trip (was v1 --live block).
#
# Preconditions:
#   - mode=mock: mock_feishu running on :8101 (started by scenario/teardown
#                or by this script's own setup below if not up).
#   - mode=lark: ~/.esr/live.env exported with FEISHU_APP_ID,
#                FEISHU_APP_SECRET, FEISHU_TEST_CHAT_ID.
#   - adapters.yaml for instance=$instance already persisted from a previous
#                `esr adapter add` (L0 asserts auto-restore).
#
# All L* artifacts are correlated by a single $nonce embedded in $tag.
# ===========================================================================

if [[ "$mode" == "lark" ]]; then
  env_file="$HOME/.esr/live.env"
  if [[ ! -f "$env_file" ]]; then
    echo "NO LIVE CREDENTIALS — set $env_file with FEISHU_APP_ID etc."
    exit 2
  fi
  # shellcheck source=/dev/null
  source "$env_file"
  : "${FEISHU_APP_ID:?not set}"
  : "${FEISHU_APP_SECRET:?not set}"
  : "${FEISHU_TEST_CHAT_ID:?not set}"
  instance="smoke-live"
else
  # mock mode: synthesize the same env vars so downstream L* code is uniform.
  FEISHU_APP_ID="cli_mock"
  FEISHU_APP_SECRET="mock-secret"
  FEISHU_TEST_CHAT_ID="oc_m1"
  instance="smoke-mock"
  export FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_TEST_CHAT_ID
fi

nonce="SMOKE-$(openssl rand -hex 4 | tr 'a-f' 'A-F')"
tag="smoke-$nonce"
log_glob="$HOME/.esrd/$instance/logs/*.log"
echo
echo "smoke-test mode : $mode"
echo "smoke-test nonce: $nonce"
echo "smoke-test tag  : $tag"

# --------------------------------------------------------------------------
# Message-sender shims. lark_post / lark_find_bot_reply swap implementations
# based on $mode. All L* checks below call these two functions uniformly.
# --------------------------------------------------------------------------

if [[ "$mode" == "lark" ]]; then
  lark_post() {
    local text="$1"
    LARK_TEXT="$text" uv run --project py python <<'PY'
import json, os, sys
import lark_oapi as lark
from lark_oapi.api.im.v1 import CreateMessageRequest, CreateMessageRequestBody
client = (lark.Client.builder()
          .app_id(os.environ["FEISHU_APP_ID"])
          .app_secret(os.environ["FEISHU_APP_SECRET"])
          .build())
req = (CreateMessageRequest.builder()
       .receive_id_type("chat_id")
       .request_body(CreateMessageRequestBody.builder()
                     .receive_id(os.environ["FEISHU_TEST_CHAT_ID"])
                     .msg_type("text")
                     .content(json.dumps({"text": os.environ["LARK_TEXT"]},
                                         ensure_ascii=False))
                     .build())
       .build())
resp = client.im.v1.message.create(req)
if resp.code != 0 or not resp.data:
    sys.stderr.write(f"Lark POST failed: code={resp.code} msg={resp.msg}\n")
    sys.exit(1)
print(resp.data.message_id)
PY
  }

  lark_find_bot_reply() {
    local needle="$1" exclude_id="$2"
    NEEDLE="$needle" EXCLUDE_ID="$exclude_id" uv run --project py python <<'PY' 2>/dev/null
import json, os, sys
import lark_oapi as lark
from lark_oapi.api.im.v1 import ListMessageRequest
client = (lark.Client.builder()
          .app_id(os.environ["FEISHU_APP_ID"])
          .app_secret(os.environ["FEISHU_APP_SECRET"])
          .build())
req = (ListMessageRequest.builder()
       .container_id_type("chat")
       .container_id(os.environ["FEISHU_TEST_CHAT_ID"])
       .sort_type("ByCreateTimeDesc")
       .page_size(20)
       .build())
resp = client.im.v1.message.list(req)
if resp.code != 0 or not resp.data or not resp.data.items:
    sys.exit(0)
needle = os.environ["NEEDLE"]
exclude = os.environ["EXCLUDE_ID"]
for m in resp.data.items:
    if m.message_id == exclude:
        continue
    try:
        body = json.loads(m.body.content) if m.body and m.body.content else {}
    except Exception:
        body = {}
    text = body.get("text", "") + " " + json.dumps(body, ensure_ascii=False)
    if needle in text and getattr(m.sender, "sender_type", None) == "app":
        print(m.message_id)
        sys.exit(0)
sys.exit(0)
PY
  }
else
  # mock mode: post against mock_feishu HTTP shim on :8101.
  # Ensure mock_feishu is up (the earlier scenario may have torn it down).
  if ! nc -z 127.0.0.1 8101 2>/dev/null; then
    uv run --project py python scripts/mock_feishu.py --port 8101 \
        > /tmp/mock-feishu.gate.log 2>&1 &
    echo $! > /tmp/mock-feishu.gate.pid
    for i in $(seq 1 15); do
      nc -z 127.0.0.1 8101 2>/dev/null && break
      sleep 1
    done
  fi

  lark_post() {
    local text="$1"
    curl -sS -X POST http://127.0.0.1:8101/push_inbound \
      -H 'content-type: application/json' \
      -d "$(uv run --project py python -c '
import json, os, sys
print(json.dumps({
  "chat_id": os.environ["FEISHU_TEST_CHAT_ID"],
  "app_id":  os.environ["FEISHU_APP_ID"],
  "user":    "u1",
  "text":    sys.argv[1],
}))' "$text")" | uv run --project py python -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
print(d.get("message_id", ""))'
  }

  lark_find_bot_reply() {
    local needle="$1" exclude_id="$2"
    # Use a temp file to avoid heredoc-vs-pipe stdin conflict (bash quirk:
    # `cmd | python <<'EOF'` feeds both pipe data and heredoc to python's stdin).
    local tmp_msgs; tmp_msgs=$(mktemp /tmp/fg_sent_msgs.XXXXXXXX)
    curl -sS "http://127.0.0.1:8101/sent_messages" > "$tmp_msgs" 2>/dev/null || true
    MSGS_FILE="$tmp_msgs" NEEDLE="$needle" EXCLUDE_ID="$exclude_id" \
      uv run --project py python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    items = json.loads(open(os.environ["MSGS_FILE"]).read() or "[]")
except Exception:
    sys.exit(0)
needle = os.environ["NEEDLE"]
exclude = os.environ["EXCLUDE_ID"]
for m in reversed(items):  # newest last
    if m.get("message_id") == exclude:
        continue
    text = (m.get("text") or "") + " " + json.dumps(m, ensure_ascii=False)
    if needle in text and m.get("sender_type", "app") == "app":
        print(m.get("message_id", ""))
        sys.exit(0)
sys.exit(0)
PY
    rm -f "$tmp_msgs"
  }
fi

# -------------------- L0: adapters.yaml auto-restore --------------------
section "7/13 live L0 — start esrd without manual adapter add (P7 auto-restore)"

# Pre-populate adapters.yaml for the smoke instance so L0 auto-restore
# can verify it (the file is the prerequisite for restore_adapters_from_disk).
mkdir -p "$HOME/.esrd/$instance"
cat > "$HOME/.esrd/$instance/adapters.yaml" <<ADAPTERS_EOF
instances:
  feishu-mock:
    type: feishu
    config:
      app_id: $FEISHU_APP_ID
      app_secret: $FEISHU_APP_SECRET
      base_url: http://127.0.0.1:8101
ADAPTERS_EOF
# Also write to the "default" instance path so the runtime's restore_adapters_from_disk
# finds it (application.ex reads ~/.esrd/default/adapters.yaml).
mkdir -p "$HOME/.esrd/default"
cat > "$HOME/.esrd/default/adapters.yaml" <<ADAPTERS_EOF
instances:
  feishu-mock:
    type: feishu
    config:
      app_id: $FEISHU_APP_ID
      app_secret: $FEISHU_APP_SECRET
      base_url: http://127.0.0.1:8101
ADAPTERS_EOF

if ! scripts/esrd.sh start --instance="$instance" >/tmp/fg.live.esrd.log 2>&1; then
  echo "FAIL to start esrd"; tail -20 /tmp/fg.live.esrd.log; exit 1
fi
trap 'scripts/esrd.sh stop --instance='"$instance"' >/dev/null 2>&1 || true;
      kill -9 $(cat /tmp/mock-feishu.gate.pid 2>/dev/null) 2>/dev/null || true;
      pkill -f "mock_cc_worker.py" 2>/dev/null || true;
      rm -f /tmp/mock-feishu.gate.pid' EXIT
# Give restore_state_from_disk time to re-instantiate feishu-app-session.
sleep 5

# 2026-05-05 cli-channel→slash migration: L0a/L0b switched to the
# Elixir escript. `runtime/esr <kind> [args...]` routes through the
# admin_queue → slash dispatch (no more cli:* WS topic). Both
# ESR_INSTANCE + ESRD_HOME are exported per call so the escript's
# admin_queue path matches the running esrd's queue:
#   - escript's `cmd_exec_kind` defaults ESRD_HOME → `~/.esrd-dev`,
#   - the runtime's `Esr.Paths.esrd_home/0` defaults to `~/.esrd`,
#   - and esrd.sh starts the runtime with ESRD_HOME=$HOME/.esrd unless
#     overridden. The two defaults disagree, so leaving either env var
#     unset would silently route the queue file to a path the daemon
#     watcher isn't subscribed to (L0a would time out waiting for
#     completed/<id>.yaml). Explicit exports avoid the trap.
export ESRD_HOME="${ESRD_HOME:-$HOME/.esrd}"
l0_adapters=$(ESR_INSTANCE="$instance" runtime/esr adapters list 2>/tmp/fg.live.l0a.log \
              | grep -F "$FEISHU_APP_ID" | head -1 || true)
l0_actor=$(ESR_INSTANCE="$instance" runtime/esr actors list 2>/tmp/fg.live.l0b.log \
           | grep -F "feishu-app:$FEISHU_APP_ID" | head -1 || true)
if [[ -z "$l0_adapters" ]]; then
  echo "FAIL — L0a: esr adapters list does not show the feishu instance"
  echo "(check ~/.esrd/$instance/adapters.yaml is pre-populated from prior run)"
  cat /tmp/fg.live.l0a.log
  exit 1
fi
if [[ -z "$l0_actor" ]]; then
  echo "FAIL — L0b: esr actors list does not show feishu-app:$FEISHU_APP_ID peer"
  cat /tmp/fg.live.l0b.log
  exit 1
fi
echo "  L0a adapters line : $(echo "$l0_adapters" | head -c 120)"
echo "  L0b actor line    : $(echo "$l0_actor" | head -c 120)"

# Register the diagnostic workspace (required by /new-session esr-dev).
section "8/13 live L0 — workspace add esr-dev (role=diagnostic)"
# 2026-05-05 cli-channel→slash migration: workspace registration goes
# through `/new-workspace` slash command via the escript, not the
# deleted `cli:workspace/register` WS topic. The slash command is
# idempotent — `action: created` first run, `action: added_chat` /
# `already_bound` thereafter — so this step survives a re-run without
# manual workspaces.yaml cleanup.
ESR_INSTANCE="$instance" runtime/esr exec /new-workspace \
    name=esr-dev \
    role=diagnostic \
    start_cmd=scripts/esr-cc.sh \
    chat_id="$FEISHU_TEST_CHAT_ID" \
    app_id="$FEISHU_APP_ID" \
    >/tmp/fg.live.ws.log 2>&1 || {
  echo "FAIL to add workspace"; cat /tmp/fg.live.ws.log; exit 1; }

# -------------------- L1: /new-session spawn --------------------
section "9/13 live L1 — /new-session esr-dev name=$tag"
# Spawn mock_cc_worker BEFORE posting /new-session so it's ready to join
# cli:channel/$tag as soon as feishu-thread-session is instantiated.
uv run --project py python scripts/mock_cc_worker.py \
    --session "$tag" --chat-id "$FEISHU_TEST_CHAT_ID" --app-id "$FEISHU_APP_ID" \
    > "/tmp/mock_cc.$tag.log" 2>&1 &
echo $! > "/tmp/mock_cc.$tag.pid"
sleep 1  # give worker time to connect before the topology spawns

l1_message_id=$(lark_post "/new-session esr-dev name=$tag") || {
  echo "FAIL — L1 post error"; exit 1; }
if [[ -z "$l1_message_id" ]]; then
  echo "FAIL — L1 post returned no message_id"; exit 1
fi
echo "  L1 message_id: $l1_message_id"

# Wait up to 30s for two sub-artifacts:
#   L1a: bot reply "session $tag ready" (contains $nonce via $tag)
#   L1b: esrd log line "actor_id=cc:$tag"
deadline=$(( $(date +%s) + 30 ))
l1_ready_id="" l1_log_line=""
while (( $(date +%s) < deadline )); do
  [[ -z "$l1_ready_id" ]] && \
    l1_ready_id=$(lark_find_bot_reply "session $tag ready" "$l1_message_id")
  [[ -z "$l1_log_line" ]] && \
    l1_log_line=$(grep -F "actor_id=cc:$tag" $log_glob 2>/dev/null | tail -1 || true)
  [[ -n "$l1_ready_id" && -n "$l1_log_line" ]] && break
  sleep 2
done
if [[ -z "$l1_ready_id" ]]; then
  echo "FAIL — L1: no bot reply 'session $tag ready' within 30s"; exit 1
fi
if [[ -z "$l1_log_line" ]]; then
  echo "FAIL — L1: esrd log missing actor_id=cc:$tag"; exit 1
fi
echo "  L1 ready reply    : $l1_ready_id"
echo "  L1 esrd actor line: $(echo "$l1_log_line" | head -c 120)"

# -------------------- L2: ECHO-PROBE → _echo(nonce) → reply --------------------
section "10/13 live L2 — ECHO-PROBE: $nonce (MCP _echo round-trip)"
l2_probe_id=$(lark_post "ECHO-PROBE: $nonce") || {
  echo "FAIL — L2 post error"; exit 1; }
echo "  L2 probe message_id: $l2_probe_id"

deadline=$(( $(date +%s) + 30 ))
l2_ack_id="" l2_tool_log=""
while (( $(date +%s) < deadline )); do
  [[ -z "$l2_ack_id" ]] && \
    l2_ack_id=$(lark_find_bot_reply "$nonce" "$l2_probe_id")
  if [[ -z "$l2_tool_log" ]]; then
    l2_tool_log=$(grep -E "tool_invoke.*_echo.*req_id=" $log_glob 2>/dev/null \
                  | grep -F "args.nonce=\"$nonce\"" | tail -1 || true)
  fi
  [[ -n "$l2_ack_id" && -n "$l2_tool_log" ]] && break
  sleep 2
done
if [[ -z "$l2_ack_id" ]]; then
  echo "FAIL — L2: no bot reply containing nonce $nonce within 30s"; exit 1
fi
if [[ -z "$l2_tool_log" ]]; then
  echo "FAIL — L2: esrd log missing tool_invoke _echo line with args.nonce=\"$nonce\""
  exit 1
fi
echo "  L2 ack message_id  : $l2_ack_id"
echo "  L2 tool_invoke log : $(echo "$l2_tool_log" | head -c 140)"

# -------------------- L5: /end-session → session_killed --------------------
# 2026-05-06: was `uv run --project py esr cmd stop feishu-thread-session ...`
# — that Python CLI sub-command was P3-13-dead since Esr.Topology was
# deleted, and the click CLI itself was deleted in this PR. Replaced
# with the live `/end-session` slash command via the Elixir escript;
# /end-session triggers the same Esr.Scope.End teardown path that the
# old `cmd stop` was supposed to drive once it stopped being a stub.
section "11/13 live L5 — /end-session $tag (esrd-side teardown)"
ESR_INSTANCE="$instance" runtime/esr exec /end-session name="$tag" \
    >/tmp/fg.live.l5.log 2>&1 || {
  echo "FAIL — L5 /end-session returned non-zero"
  cat /tmp/fg.live.l5.log; exit 1; }

deadline=$(( $(date +%s) + 10 ))
l5_log_line=""
while (( $(date +%s) < deadline )); do
  [[ -z "$l5_log_line" ]] && \
    l5_log_line=$(grep -F "session_killed published session_id=$tag" $log_glob \
                  2>/dev/null | tail -1 || true)
  [[ -n "$l5_log_line" ]] && break
  sleep 1
done
if [[ -z "$l5_log_line" ]]; then
  echo "FAIL — L5: esrd log missing 'session_killed published session_id=$tag'"
  exit 1
fi
echo "  L5 esrd log line : $(echo "$l5_log_line" | head -c 140)"

# -------------------- L6: parallel isolation via @-addressing --------------------
section "12/13 live L6 — parallel @${tag}-a vs @${tag}-b isolation"
# Spawn mock_cc_workers for both sessions before posting /new-session.
uv run --project py python scripts/mock_cc_worker.py \
    --session "${tag}-a" --chat-id "$FEISHU_TEST_CHAT_ID" --app-id "$FEISHU_APP_ID" \
    > "/tmp/mock_cc.${tag}-a.log" 2>&1 &
echo $! > "/tmp/mock_cc.${tag}-a.pid"
uv run --project py python scripts/mock_cc_worker.py \
    --session "${tag}-b" --chat-id "$FEISHU_TEST_CHAT_ID" --app-id "$FEISHU_APP_ID" \
    > "/tmp/mock_cc.${tag}-b.log" 2>&1 &
echo $! > "/tmp/mock_cc.${tag}-b.pid"
sleep 1  # give workers time to connect

l6a_spawn_id=$(lark_post "/new-session esr-dev name=${tag}-a") || {
  echo "FAIL — L6 spawn-a post error"; exit 1; }
l6b_spawn_id=$(lark_post "/new-session esr-dev name=${tag}-b") || {
  echo "FAIL — L6 spawn-b post error"; exit 1; }

# Wait for both sessions to be ready (bot reply "session ... ready").
deadline=$(( $(date +%s) + 30 ))
l6a_ready="" l6b_ready=""
while (( $(date +%s) < deadline )); do
  [[ -z "$l6a_ready" ]] && \
    l6a_ready=$(lark_find_bot_reply "session ${tag}-a ready" "$l6a_spawn_id")
  [[ -z "$l6b_ready" ]] && \
    l6b_ready=$(lark_find_bot_reply "session ${tag}-b ready" "$l6b_spawn_id")
  [[ -n "$l6a_ready" && -n "$l6b_ready" ]] && break
  sleep 2
done
if [[ -z "$l6a_ready" || -z "$l6b_ready" ]]; then
  echo "FAIL — L6: one or both parallel sessions did not report ready"
  echo "  a=$l6a_ready  b=$l6b_ready"
  exit 1
fi

# Send @${tag}-a only. Use a sub-nonce so we can distinguish from L2's $nonce
# in the L6 state assertions.
only_a_nonce="only-a-$nonce"
l6_probe_id=$(lark_post "@${tag}-a ECHO-PROBE: $only_a_nonce") || {
  echo "FAIL — L6 @-addressed probe post error"; exit 1; }
echo "  L6 probe message_id: $l6_probe_id"

# Wait up to 30s for session a's reply with the sub-nonce.
deadline=$(( $(date +%s) + 30 ))
l6a_ack_id=""
while (( $(date +%s) < deadline )); do
  l6a_ack_id=$(lark_find_bot_reply "$only_a_nonce" "$l6_probe_id")
  [[ -n "$l6a_ack_id" ]] && break
  sleep 2
done
if [[ -z "$l6a_ack_id" ]]; then
  echo "FAIL — L6a: session ${tag}-a did not echo $only_a_nonce"; exit 1
fi

# Assert session a's mock_cc log contains the sub-nonce.
if ! grep -qF "$only_a_nonce" "/tmp/mock_cc.${tag}-a.log" 2>/dev/null; then
  echo "FAIL — L6a: mock_cc.${tag}-a.log does NOT contain $only_a_nonce"
  cat "/tmp/mock_cc.${tag}-a.log" | tail -20 || true
  exit 1
fi

# Assert session b's mock_cc log does NOT contain the sub-nonce.
if grep -qF "$only_a_nonce" "/tmp/mock_cc.${tag}-b.log" 2>/dev/null; then
  echo "FAIL — L6b: mock_cc.${tag}-b.log LEAKED $only_a_nonce (isolation broken)"
  cat "/tmp/mock_cc.${tag}-b.log" | tail -20 || true
  exit 1
fi
echo "  L6a ack message_id : $l6a_ack_id"
echo "  L6a log contains   : $only_a_nonce (ok)"
echo "  L6b log excludes   : $only_a_nonce (ok)"

# Best-effort cleanup of the L6 sessions (EXIT trap stops esrd either way).
# 2026-05-06: Python CLI deleted; using /end-session via the escript.
ESR_INSTANCE="$instance" runtime/esr exec /end-session name="${tag}-a" \
    >/dev/null 2>&1 || true
ESR_INSTANCE="$instance" runtime/esr exec /end-session name="${tag}-b" \
    >/dev/null 2>&1 || true
# Kill mock_cc_workers
kill "$(cat "/tmp/mock_cc.${tag}-a.pid" 2>/dev/null)" 2>/dev/null || true
kill "$(cat "/tmp/mock_cc.${tag}-b.pid" 2>/dev/null)" 2>/dev/null || true

# -------------------- Verdict --------------------
section "13/13 verdict"
dt=$(( $(date +%s) - ts ))
echo
echo "FINAL GATE v2 PASSED — mode=$mode; nonce=$nonce; round-trip=${dt}s"
echo "  L0 adapters+actor   : feishu-app:$FEISHU_APP_ID auto-restored"
echo "  L1 ready reply      : $l1_ready_id"
echo "  L1 actor log line   : cc:$tag present"
echo "  L2 ack reply        : $l2_ack_id"
echo "  L2 tool_invoke log  : _echo args.nonce=\"$nonce\""
echo "  L5 session_killed   : session_id=$tag"
echo "  L6a ack reply       : $l6a_ack_id (only-a-$nonce)"
echo "  L6b isolation       : mock_cc.${tag}-b.log free of only-a-$nonce"

# Courtesy notice back to the chat when running against real Lark
# (best effort; never fails the gate).
if [[ "$mode" == "lark" ]]; then
  LARK_TEXT="ESR v0.2 COMPLETE — nonce $nonce observed end-to-end in ${dt}s (L0..L6)." \
    uv run --project py python <<'PY' >/dev/null 2>&1 || true
import json, os
import lark_oapi as lark
from lark_oapi.api.im.v1 import CreateMessageRequest, CreateMessageRequestBody
client = (lark.Client.builder()
          .app_id(os.environ["FEISHU_APP_ID"])
          .app_secret(os.environ["FEISHU_APP_SECRET"])
          .build())
req = (CreateMessageRequest.builder()
       .receive_id_type("chat_id")
       .request_body(CreateMessageRequestBody.builder()
                     .receive_id(os.environ["FEISHU_TEST_CHAT_ID"])
                     .msg_type("text")
                     .content(json.dumps({"text": os.environ["LARK_TEXT"]},
                                         ensure_ascii=False))
                     .build())
       .build())
client.im.v1.message.create(req)
PY
fi

exit 0
