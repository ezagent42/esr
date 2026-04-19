#!/usr/bin/env bash
# e2e-cc.sh — Phase 8e scenario start_cmd for tmux_proxy's init_directive.
#
# The feishu-thread-session pattern's tmux node carries:
#   init_directive: { action: new_session, args.start_cmd: ./e2e-cc.sh }
#
# cc_tmux runs `tmux new-session -d -s <id> <this-script>`. Before
# execing the mock CC binary we print a `[esr-cc] session=<name>`
# sentinel so final_gate.sh --live's L3 artifact (tmux capture-pane +
# grep $nonce) lands: the session name IS the smoke nonce, the line
# carrying it goes into the pane, and cc_tmux.emit_events parses it
# as cc_output to close the loop back up to Feishu (L4).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || echo unknown)"
echo "[esr-cc] session=${session_name}"
exec uv run --project py python scripts/mock_cc.py
