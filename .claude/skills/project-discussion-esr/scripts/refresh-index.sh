#!/bin/bash
# Refresh module index when Step 0 detects stale paths / renamed files.
# Usage:
#   refresh-index.sh                 # rescan everything (slow)
#   refresh-index.sh --module NAME   # rescan one module (fast)
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ARTIFACTS="$ROOT/.artifacts"
MODULE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module) MODULE="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--module NAME]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

SCAN="$HOME/.claude/plugins/cache/ezagent42/dev-loop-skills/0.1.0/skills/skill-0-project-builder/scripts/scan-project.sh"

if [ -z "$MODULE" ]; then
    echo "[refresh-index] Full rescan…"
    bash "$SCAN" --project-root "$ROOT" --output "$ARTIFACTS/bootstrap/manifest.json"
    echo "[refresh-index] Full rescan done. Re-run Skill 0 Step 3 subagents for stale modules, or invoke the module-specific test-runner to verify."
else
    echo "[refresh-index] Re-scanning module=$MODULE"
    case "$MODULE" in
        py-*|adapter-*|handler-*|scripts|patterns-roles-scenarios|runtime-*)
            # Just re-run the module's test-runner — that re-verifies the code paths
            SKILL_DIR="$ROOT/.claude/skills/project-discussion-esr/scripts"
            if [ -x "$SKILL_DIR/test-$MODULE.sh" ]; then
                echo "[refresh-index] Re-running test-$MODULE.sh to validate index…"
                bash "$SKILL_DIR/test-$MODULE.sh"
            else
                echo "[refresh-index] No test-runner for $MODULE. Falling back to full rescan." >&2
                bash "$SCAN" --project-root "$ROOT" --output "$ARTIFACTS/bootstrap/manifest.json"
            fi
            ;;
        *)
            echo "[refresh-index] Unknown module: $MODULE" >&2
            echo "Known modules: py-sdk-core py-cli py-ipc py-verify adapter-{feishu,cc-tmux,cc-mcp} handler-{feishu-app,feishu-thread,cc-session,tmux-proxy} scripts patterns-roles-scenarios runtime-{core,subsystems,web}" >&2
            exit 1
            ;;
    esac
fi
echo "[refresh-index] Done."
