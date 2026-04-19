#!/usr/bin/env bash
# External verdict (spec §4.1, §4.1.1, §8). Authored by the user/Claude before
# loop launch; SHA-pinned in scripts/final_gate.sh.sha256; loop is forbidden
# to modify (LG-4).
#
# Usage:
#   bash scripts/final_gate.sh --mock   # loop-runnable; gate #5 of Final Gate
#   bash scripts/final_gate.sh --live   # loop-runnable; gate #8 of Final Gate
#                                       # requires ~/.esr/live.env
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

mode="${1:-}"
if [[ "$mode" != "--mock" && "$mode" != "--live" ]]; then
  echo "usage: $0 --mock | --live" >&2
  exit 2
fi

fail=0
section() { echo; echo "=== $* ==="; }

if [[ "$mode" == "--mock" ]]; then
  section "1/7 make test"
  if ! make test >/tmp/fg.test.log 2>&1; then
    echo "FAIL"; tail -40 /tmp/fg.test.log; fail=1
  fi

  section "2/7 verify_prd_matrix.py"
  if ! uv run --project py python scripts/verify_prd_matrix.py >/tmp/fg.matrix.log 2>&1; then
    echo "FAIL"; cat /tmp/fg.matrix.log; fail=1
  fi

  section "3/7 loopguard"
  if ! bash scripts/loopguard.sh >/tmp/fg.lg.log 2>&1; then
    echo "FAIL"; tail -20 /tmp/fg.lg.log; fail=1
  fi

  section "4/7 scenario run e2e-feishu-cc (mock)"
  if ! uv run --project py esr scenario run e2e-feishu-cc >/tmp/fg.scn.log 2>&1; then
    echo "FAIL"; tail -20 /tmp/fg.scn.log; fail=1
  fi

  section "5/7 ledger integrity"
  if ! uv run --project py python scripts/verify_ledger_append_only.py >/tmp/fg.led.log 2>&1; then
    echo "FAIL"; cat /tmp/fg.led.log; fail=1
  fi

  section "6/7 PRD acceptance manifest"
  if ! uv run --project py python scripts/verify_prd_acceptance.py \
      --manifest docs/superpowers/prds/acceptance-manifest.yaml >/tmp/fg.acc.log 2>&1; then
    echo "FAIL"; cat /tmp/fg.acc.log; fail=1
  fi

  section "7/7 no BLOCKED in ledger"
  if grep -qE '<promise>BLOCKED:' docs/ralph-loop-ledger.md 2>/dev/null; then
    echo "FAIL — BLOCKED record in ledger"; fail=1
  fi

  if [[ $fail -eq 0 ]]; then
    echo
    echo "FINAL GATE MOCK PASSED"
    exit 0
  else
    echo
    echo "FINAL GATE MOCK FAILED"
    exit 1
  fi
fi

# --live path — 4-artifact nonce verification (spec §4.1.1).
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

nonce="SMOKE-$(openssl rand -hex 4 | tr 'a-f' 'A-F')"
ts=$(date +%s)
thread_id="smoke-$nonce"
echo "smoke-test nonce: $nonce"

section "live 1/5 — start esrd (smoke-live instance)"
if ! scripts/esrd.sh start --instance=smoke-live >/tmp/fg.live.esrd.log 2>&1; then
  echo "FAIL to start esrd"; tail -20 /tmp/fg.live.esrd.log; exit 1
fi
trap 'scripts/esrd.sh stop --instance=smoke-live >/dev/null 2>&1 || true' EXIT
sleep 2

section "live 2/5 — register feishu adapter for smoke-live"
uv run --project py esr adapter add feishu-smoke \
    --type feishu --app-id "$FEISHU_APP_ID" --app-secret "$FEISHU_APP_SECRET" \
    >/tmp/fg.live.add.log 2>&1 || { echo "FAIL to add adapter"; cat /tmp/fg.live.add.log; exit 1; }

section "live 3/5 — post /new-thread \$nonce (L1)"
l1_message_id=$(uv run --project py python <<PY
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
                     .content(json.dumps({"text": "/new-thread $thread_id"},
                                         ensure_ascii=False))
                     .build())
       .build())
resp = client.im.v1.message.create(req)
if resp.code != 0 or not resp.data:
    sys.stderr.write(f"Lark POST failed: code={resp.code} msg={resp.msg}\n")
    sys.exit(1)
print(resp.data.message_id)
PY
)
if [[ -z "$l1_message_id" ]]; then
  echo "FAIL — L1 Lark POST did not return a message_id"; exit 1
fi
echo "  L1 message_id: $l1_message_id"

section "live 4/5 — poll L2+L3+L4 (up to 60s)"
deadline=$(( $(date +%s) + 60 ))
l2_log="" l3_pane="" l4_server=""
while (( $(date +%s) < deadline )); do
  [[ -z "$l2_log" ]] && l2_log=$(grep -F "$nonce" ~/.esrd/smoke-live/logs/*.log 2>/dev/null | tail -1 || true)
  [[ -z "$l3_pane" ]] && l3_pane=$(tmux capture-pane -t "$thread_id" -p 2>/dev/null | grep -F "$nonce" | tail -1 || true)
  if [[ -z "$l4_server" ]]; then
    l4_server=$(uv run --project py python <<PY 2>/dev/null
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
for m in resp.data.items:
    if m.message_id == "$l1_message_id":
        continue
    try:
        body = json.loads(m.body.content) if m.body and m.body.content else {}
    except Exception:
        body = {}
    text = body.get("text", "") + " " + json.dumps(body, ensure_ascii=False)
    if "$nonce" in text and getattr(m.sender, "sender_type", None) == "app":
        print(m.message_id)
        sys.exit(0)
sys.exit(0)
PY
)
  fi
  [[ -n "$l2_log" && -n "$l3_pane" && -n "$l4_server" ]] && break
  sleep 2
done

section "live 5/5 — verify 4 artifacts"
missing=()
[[ -z "$l2_log"    ]] && missing+=("L2: esrd log line with nonce $nonce")
[[ -z "$l3_pane"   ]] && missing+=("L3: tmux pane content with nonce $nonce")
[[ -z "$l4_server" ]] && missing+=("L4: Lark server-side bot reply containing nonce $nonce")
if (( ${#missing[@]} > 0 )); then
  echo "FINAL GATE LIVE FAILED — missing artifacts:"
  printf '  - %s\n' "${missing[@]}"
  exit 1
fi

round_trip_s=$(( $(date +%s) - ts ))
echo
echo "FINAL GATE LIVE PASSED — nonce=$nonce; round-trip observed in ${round_trip_s}s"
echo "  L1 message_id : $l1_message_id"
echo "  L2 esrd log   : $(echo "$l2_log" | head -c 120)..."
echo "  L3 tmux pane  : $(echo "$l3_pane" | head -c 120)..."
echo "  L4 server echo: $l4_server"

uv run --project py python <<PY >/dev/null 2>&1 || true
import json, os
import lark_oapi as lark
from lark_oapi.api.im.v1 import CreateMessageRequest, CreateMessageRequestBody
msg = (f"✓ ESR v0.1 COMPLETE — nonce $nonce observed end-to-end in ${round_trip_s}s.\n"
       f"   L1 message_id=$l1_message_id  L4 server echo=$l4_server")
client = (lark.Client.builder()
          .app_id(os.environ["FEISHU_APP_ID"])
          .app_secret(os.environ["FEISHU_APP_SECRET"])
          .build())
req = (CreateMessageRequest.builder()
       .receive_id_type("chat_id")
       .request_body(CreateMessageRequestBody.builder()
                     .receive_id(os.environ["FEISHU_TEST_CHAT_ID"])
                     .msg_type("text")
                     .content(json.dumps({"text": msg}, ensure_ascii=False))
                     .build())
       .build())
client.im.v1.message.create(req)
PY

exit 0
