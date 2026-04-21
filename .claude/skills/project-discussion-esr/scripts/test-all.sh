#!/bin/bash
# Full ESR test suite runner. Equivalent of `make test` + extras.
# Baseline: 636 tests | 630 passed | 5 failed | 1 skipped
set -u
cd "$(git rev-parse --show-toplevel)"
ROOT="$(pwd)"
SKILL_DIR="$ROOT/.claude/skills/project-discussion-esr/scripts"

rc=0
for s in py-sdk-core py-cli py-ipc py-verify \
         adapter-feishu adapter-cc-tmux adapter-cc-mcp \
         handler-feishu-app handler-feishu-thread handler-cc-session handler-tmux-proxy \
         scripts patterns-roles-scenarios \
         runtime-core runtime-subsystems runtime-web; do
  echo ""
  echo "============================================================"
  echo "  $s"
  echo "============================================================"
  bash "$SKILL_DIR/test-$s.sh" "$@" || rc=$?
done
echo ""
echo "============================================================"
echo "  Overall exit code: $rc"
echo "============================================================"
exit "$rc"
