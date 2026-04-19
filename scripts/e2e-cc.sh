#!/usr/bin/env bash
# e2e-cc.sh — Phase 8e scenario start_cmd for tmux_proxy's init_directive.
#
# The feishu-thread-session pattern's tmux node carries:
#   init_directive: { action: new_session, args.start_cmd: ./e2e-cc.sh }
#
# cc_tmux runs `tmux new-session -d -s <id> <this-script>`. We exec the mock
# CC binary directly — no arguments — so tmux's first pane is hosting the
# mock, matching the real cc_tmux→cc handshake but with zero external deps.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
exec uv run --project py python scripts/mock_cc.py
