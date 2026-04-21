#!/usr/bin/env bash
# uninstall.sh — mirror of install.sh.
#
# Usage: uninstall.sh [--env=prod|dev|both]   (default: both)
#
# Per env:
#   - `launchctl bootout gui/$UID/com.ezagent.esrd{-dev}` (ignore-not-loaded)
#   - Remove ~/Library/LaunchAgents/com.ezagent.esrd{-dev}.plist
#   - If dev: also remove .git/hooks/post-merge from the dev worktree
#
# Does NOT touch $ESRD_HOME contents — data/logs are preserved for inspection.

set -u

env_target="${1:---env=both}"

DEV_WORKTREE="${HOME}/Workspace/esr/.claude/worktrees/dev"

uninstall_one() {
  local name="$1"                 # esrd | esrd-dev
  local label="com.ezagent.${name}"
  local target="${HOME}/Library/LaunchAgents/com.ezagent.${name}.plist"

  launchctl bootout "gui/${UID}/${label}" 2>/dev/null || true
  rm -f "$target"
  echo "✓ $name uninstalled (data at \$ESRD_HOME preserved)"
}

uninstall_dev_hook() {
  if [[ ! -d "${DEV_WORKTREE}/.git" && ! -f "${DEV_WORKTREE}/.git" ]]; then
    return 0
  fi
  local git_common
  git_common="$(git -C "${DEV_WORKTREE}" rev-parse --git-path hooks 2>/dev/null)" || return 0
  if [[ "$git_common" != /* ]]; then
    git_common="${DEV_WORKTREE}/${git_common}"
  fi
  if [[ -f "${git_common}/post-merge" ]]; then
    rm -f "${git_common}/post-merge"
    echo "✓ post-merge hook removed from ${git_common}/"
  fi
}

case "$env_target" in
  --env=prod|prod)
    uninstall_one esrd
    ;;
  --env=dev|dev)
    uninstall_one esrd-dev
    uninstall_dev_hook
    ;;
  --env=both|both)
    "$0" --env=prod
    "$0" --env=dev
    ;;
  *)
    echo "Usage: $0 [--env=prod|dev|both]" >&2
    exit 2
    ;;
esac
