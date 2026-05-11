#!/usr/bin/env bash
# scripts/hooks/replay-guide-reminder.sh — PostToolUse hook fired when
# Claude Code Edits/Writes a file. If the file matches a command handler
# path, nudge the agent/dev to run scripts/replay-guide.sh on the
# relevant guide before committing. Spec §3.5.

set -Eeuo pipefail

input="$(cat)"
fp="$(printf '%s' "${input}" | jq -r '.tool_input.file_path // empty')"
if [[ -z "${fp}" ]]; then
  exit 0
fi

case "${fp}" in
  runtime/lib/esr/commands/*.ex|*/runtime/lib/esr/commands/*.ex)
    base="$(basename "${fp}" .ex | tr A-Z a-z)"
    cat >&2 <<EOF
⚠️  You edited ${fp}.
Before committing, run scripts/replay-guide.sh against any guide that
references this command. Find candidates:
    rg "${base}" docs/guides/
EOF
    ;;
esac
