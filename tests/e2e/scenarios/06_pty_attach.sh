#!/usr/bin/env bash
# scenario 06 — `/sessions/:sid/attach` HTML shell smoke test.
#
# History: PR-22 introduced this against LiveView (`phx-hook="XtermAttach"`).
# PR-23 replaced LiveView with Phoenix.Channel + raw xterm.js
# (`<div id="term">` + `window.ESR_SID`). PR-24 swapped Phoenix.Channel
# for a raw binary WebSocket (`/attach_socket/websocket`) but the HTML
# shell shape stayed the same.
#
# This scenario only verifies the static HTML page renders correctly;
# bidirectional PubSub flow lives in `07_pty_bidir.sh`.

set -Eeuo pipefail

ESR_HOST="${ESR_PUBLIC_HOST:-127.0.0.1}"
ESR_PORT="${PORT:-4001}"
BASE_URL="http://${ESR_HOST}:${ESR_PORT}"
SID="smoke-pty-attach-$(date +%s)"

echo "[06_pty_attach] target: ${BASE_URL}/sessions/${SID}/attach"

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

# PR-24 invariants:
#   - The raw xterm.js mount div exists (id=term).
#   - The bundled JS reads window.ESR_SID, so the sid must be embedded.
#   - The bundle path matches the esbuild output mounted by Plug.Static.
for needle in '<div id="term">' "window.ESR_SID = \"${SID}\"" '/assets/app.js'; do
  if ! grep -qF "$needle" "$RESPONSE_FILE"; then
    echo "FAIL: response body does not contain expected literal '$needle'"
    echo "--- response body ---"
    head -80 "$RESPONSE_FILE"
    exit 1
  fi
done

echo "[06_pty_attach] OK — attach HTML shell renders for /sessions/${SID}/attach"
