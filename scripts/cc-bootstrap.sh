#!/usr/bin/env bash
# scripts/cc-bootstrap.sh — manually unblock a freshly-spawned claude
# session that's waiting on the `--dangerously-load-development-channels`
# warning dialog.
#
# Symptom (live-debugged 2026-05-02): after `/new-session`, claude renders
# its dev-channels warning dialog and waits for "1\r" confirmation. With
# no operator at /attach, claude hangs; cc_mcp never spawns; inbound
# notifications buffer in `cc_process.pending_notifications` forever.
#
# This script is the minimal external intervention: connects to the PTY
# attach socket as if a browser, sends the dialog answer, disconnects.
# After this, `pgrep -P <claude-pid>` should show the cc_mcp child and
# `cli:channel/<sid>` JOINED appears in the BEAM log.
#
# Usage:
#   scripts/cc-bootstrap.sh <session_id> [esrd_url]
#
# Defaults to `ws://127.0.0.1:4001` for esrd-dev. Set ESR_ESRD_URL env
# var or pass arg to override.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <session_id> [esrd_url]" >&2
  echo "example: $0 KYEMVC2OM2IF54JHTZBA ws://127.0.0.1:4001" >&2
  exit 2
fi

sid="$1"
esrd_url="${2:-${ESR_ESRD_URL:-ws://127.0.0.1:4001}}"
ws_url="${esrd_url}/attach_socket/websocket?sid=${sid}"

if ! command -v websocat >/dev/null 2>&1; then
  echo "$0: websocat not found (brew install websocat)" >&2
  exit 2
fi

echo "$0: connecting ws=${ws_url}" >&2

# Send:
#   1. JSON resize (text frame) — sets terminal cols/rows so claude
#      renders into a known viewport
#   2. wait for claude to actually render the dialog before answering
#      it. claude takes ~2-3s after spawn to open its TUI; sending "1"
#      too early is consumed by bracketed-paste mode and the dialog
#      then waits forever for an input it never sees.
#   3. "1\r" (binary frame) — answers the dev-channels warning dialog
#   4. Wait briefly so the bytes reach the PTY before the WS closes
{
  printf '{"cols":120,"rows":40}\n'
  sleep 4
  printf '1\r'
  sleep 2
} | websocat --binary -E "$ws_url" >/dev/null 2>&1

echo "$0: done; verify with:" >&2
echo "  pgrep -P \$(pgrep -f \"claude.*esr-channel\" | head -1)" >&2
echo "  tail -20 \$ESRD_HOME/<instance>/logs/launchd-stdout.log | grep '${sid}'" >&2
