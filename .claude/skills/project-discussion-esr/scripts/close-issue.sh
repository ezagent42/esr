#!/bin/bash
# Close a GitHub issue (used in Step 6 when an eval-doc is rejected and the
# linked issue should be closed).
set -euo pipefail

ISSUE_URL=""
REASON=""

usage() {
    cat <<EOF
Usage: close-issue.sh --issue-url <url> --reason <text>

Close a GitHub issue and leave a comment explaining the closure.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue-url) ISSUE_URL="$2"; shift 2 ;;
        --reason) REASON="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$ISSUE_URL" ] || { echo "--issue-url required" >&2; exit 1; }
[ -n "$REASON" ] || { echo "--reason required" >&2; exit 1; }

if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI not installed. Install via: brew install gh" >&2
    exit 1
fi

gh issue close "$ISSUE_URL" --comment "Resolved as 'not a bug' after Skill 1 triage.

Reason: $REASON" --reason "not planned"
