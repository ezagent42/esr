#!/usr/bin/env bash
# PR-22 scenario 06 — PtyProcess + AttachLive smoke test.
#
# Production topology under test:
#   1. esrd is running with PR-22 code (PtyProcess replaces TmuxProcess)
#   2. EsrWeb.AttachLive route is mounted at /sessions/:sid/attach
#   3. ESR_PUBLIC_HOST controls the URL Esr.Uri.to_http_url emits
#
# This is a SMOKE test — it doesn't drive a real session through Feishu
# (that requires the full mock_feishu harness). It verifies:
#   - /sessions/:sid/attach returns 200 with the xterm.js hook HTML
#   - The route exists and the LiveView shell renders before any real
#     session is bound.
#
# Run this against a running esrd (dev or prod). Full mock_feishu-driven
# e2e (/new-session → /attach → curl URL → /end-session) is tracked as a
# follow-up; the slash-command + LiveView surfaces have unit-test coverage
# (test/esr/admin/commands/attach_test.exs + test/esr_web/live/attach_live_test.exs).

set -Eeuo pipefail

ESR_HOST="${ESR_PUBLIC_HOST:-127.0.0.1}"
ESR_PORT="${PORT:-4001}"
BASE_URL="http://${ESR_HOST}:${ESR_PORT}"
SID="smoke-pty-attach-$(date +%s)"

echo "[06_pty_attach] target: ${BASE_URL}/sessions/${SID}/attach"

# Step 1: GET the AttachLive page. The LiveView returns 200 with the
# xterm.js hook even before a real session is bound; the hook just sees
# no PubSub messages until a real PtyProcess broadcasts.
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "$RESPONSE_FILE"' EXIT

HTTP_CODE=$(curl -sS -o "$RESPONSE_FILE" -w "%{http_code}" \
  "${BASE_URL}/sessions/${SID}/attach")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "FAIL: GET /sessions/${SID}/attach returned ${HTTP_CODE} (expected 200)"
  echo "--- response body ---"
  head -50 "$RESPONSE_FILE"
  exit 1
fi

# Step 2: assert the LiveView shell rendered the xterm.js mount div.
if ! grep -q 'phx-hook="XtermAttach"' "$RESPONSE_FILE"; then
  echo "FAIL: response body does not contain phx-hook=\"XtermAttach\""
  echo "--- response body ---"
  head -50 "$RESPONSE_FILE"
  exit 1
fi

# Step 3: assert the layout loaded the JS bundle.
if ! grep -q "/assets/app.js" "$RESPONSE_FILE"; then
  echo "FAIL: response body does not reference /assets/app.js (esbuild bundle missing?)"
  exit 1
fi

# Step 4: assert the body has the terminal id matching the sid.
if ! grep -q "term-${SID}" "$RESPONSE_FILE"; then
  echo "FAIL: response body does not contain term-${SID}"
  exit 1
fi

echo "[06_pty_attach] OK — AttachLive renders the xterm.js mount for /sessions/${SID}/attach"
