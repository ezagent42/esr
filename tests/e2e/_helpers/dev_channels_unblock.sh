#!/usr/bin/env bash
# tests/e2e/_helpers/dev_channels_unblock.sh — e2e-only fixture.
#
# Sends "1\r" over the PTY attach WebSocket to answer claude's
# `--dangerously-load-development-channels` warning dialog so cc_mcp
# can boot. Used by scenario 07 (PTY ↔ cc_mcp bidirectional verification)
# which spawns sessions unattended.
#
# Operators DO NOT need this in normal use: open
# http://${ESR_PUBLIC_HOST}:${PORT}/sessions/<sid>/attach in a browser
# and answer the dialog by hand. Pre-PR-24 there was no working /attach
# so this was the only path; now it's just an e2e fixture.
#
# Usage:
#   tests/e2e/_helpers/dev_channels_unblock.sh <session_id> [esrd_url]
#
# Defaults to `ws://127.0.0.1:4001` for esrd-dev. Set ESR_ESRD_URL env
# var or pass arg to override.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <session_id> [esrd_url]" >&2
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

# Send "1\r" as a binary frame after a 4s pre-roll. claude takes ~2-3s
# to open its TUI and render the dialog; sending "1" too early is
# consumed by bracketed-paste mode and the dialog waits forever for an
# input it never sees. The 2s post-roll lets the bytes reach the PTY
# before the WS closes from EOF on stdin.
#
# Known fragility (RCA 2026-05-04): on busy hosts claude can take
# longer than 4s to render the dialog, in which case "1\r" arrives
# during bracketed-paste startup and is silently dropped. A multi-
# frame retry approach (5×3s) was tried + reverted because websocat
# in --binary -E mode appeared to close the WS after the first stdin
# chunk regardless of subsequent writes. A more robust solution
# probably wants agent-browser keyboard input (which is known to
# reach the PTY correctly per the Standard 2 evidence test) instead
# of a bash+websocat helper. See docs/futures/todo.md.
#
# No JSON resize is sent — `websocat --binary` would put it on the
# wire as a binary frame and the server would write the literal JSON
# bytes to the PTY as keystrokes. FeishuChatProxy's boot bridge has
# already scheduled a 120×40 default-winsize ~1s after session_new
# fires, so winsize is in place before this script attaches.
{
  sleep 4
  printf '1\r'
  sleep 2
} | websocat --binary -E "$ws_url" >/dev/null 2>&1

echo "$0: done" >&2
