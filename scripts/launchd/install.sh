#!/usr/bin/env bash
# install.sh — materialize LaunchAgent plist(s) from template and bootstrap via launchctl.
#
# Usage: install.sh [--env=prod|dev|both]   (default: both)
#
# Per env:
#   - Substitutes __HOME__ / __ESRD_HOME__ / __REPO_DIR__ placeholders
#   - Copies to ~/Library/LaunchAgents/com.ezagent.esrd{-dev}.plist
#   - `launchctl bootstrap gui/$UID <target>`
#   - Waits up to ~10s for the port file to appear as a readiness signal
#   - If dev: also installs .git/hooks/post-merge in the dev worktree (if the
#     hook template exists; Phase DI-13 introduces it — skip with a warning
#     until then).

set -u

env_target="${1:---env=both}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_TEMPLATE="${SCRIPT_DIR}/../hooks/post-merge"
DEV_WORKTREE="${HOME}/Workspace/esr/.worktrees/dev"

install_one() {
  local name="$1"                 # esrd | esrd-dev
  local label="com.ezagent.${name}"
  local home="$2"                 # $HOME/.esrd or $HOME/.esrd-dev
  local repo="$3"                 # prod repo or dev worktree path
  local template="${SCRIPT_DIR}/com.ezagent.${name}.plist"
  local target="${HOME}/Library/LaunchAgents/com.ezagent.${name}.plist"

  if [[ ! -f "$template" ]]; then
    echo "✗ $name: template not found at $template" >&2
    exit 1
  fi

  mkdir -p "$home/default/logs"
  mkdir -p "${HOME}/Library/LaunchAgents"

  sed -e "s|__HOME__|${HOME}|g" \
      -e "s|__ESRD_HOME__|${home}|g" \
      -e "s|__REPO_DIR__|${repo}|g" \
      "$template" > "$target"

  # PR-N 2026-04-28: detect already-loaded LaunchAgent + alive esrd, give
  # operator a friendly hint instead of a confusing `Bootstrap failed: 5:
  # Input/output error`. This typically happens when a second operator on
  # the same macOS user runs install.sh while the first operator's esrd
  # is healthy — boot+bootstrap on a busy domain returns I/O 5.
  if launchctl print "gui/${UID}/${label}" 2>/dev/null | grep -q "state = running"; then
    local existing_port=""
    [[ -f "${home}/default/esrd.port" ]] && existing_port=$(cat "${home}/default/esrd.port" 2>/dev/null)
    local env_short="prod"
    [[ "$name" == "esrd-dev" ]] && env_short="dev"
    echo "ℹ $name is already running${existing_port:+ on port $existing_port} — skipping install."
    echo "  To restart: launchctl kickstart -k gui/\$UID/${label}"
    echo "  To replace plist (e.g. after editing the template): bash scripts/launchd/uninstall.sh --env=${env_short} && bash scripts/launchd/install.sh --env=${env_short}"
    return 0
  fi

  # If loaded but not running (crash-looping / stale), bootout first so
  # the new plist takes effect cleanly.
  launchctl bootout "gui/${UID}/${label}" 2>/dev/null || true

  if ! launchctl bootstrap "gui/${UID}" "$target"; then
    echo "✗ $name: launchctl bootstrap failed" >&2
    exit 1
  fi

  # Wait for the port file (written by Esr.Launchd.PortWriter after bind).
  local port_file="${home}/default/esrd.port"
  local i=0
  while (( i < 20 )); do
    if [[ -f "$port_file" ]]; then
      echo "✓ $name launched on port $(cat "$port_file")"
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done

  echo "✗ $name did not write port file within 10s; check logs at ${home}/default/logs/" >&2
  exit 1
}

ensure_dev_worktree() {
  # PR-H: previously dev install would silently produce a launchd plist
  # pointing at a non-existent WorkingDirectory, which trips EX_CONFIG (78)
  # at first kickstart. Auto-create the worktree against `main` so a
  # fresh operator can run install.sh --env=both without first running
  # `git worktree add` by hand.
  if [[ -d "${DEV_WORKTREE}" ]]; then
    return 0
  fi
  echo "→ dev worktree absent at ${DEV_WORKTREE}; creating against origin/main"
  local repo_root
  repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  if ! git -C "$repo_root" worktree add "${DEV_WORKTREE}" main 2>/dev/null; then
    # `main` may not exist as a local branch yet — fall back to origin/main detached.
    if ! git -C "$repo_root" worktree add --detach "${DEV_WORKTREE}" origin/main; then
      echo "✗ failed to create dev worktree at ${DEV_WORKTREE}" >&2
      exit 1
    fi
  fi
  echo "✓ dev worktree created at ${DEV_WORKTREE}"
}

install_dev_hook() {
  if [[ ! -d "${DEV_WORKTREE}/.git" && ! -f "${DEV_WORKTREE}/.git" ]]; then
    echo "⚠ dev worktree not found at ${DEV_WORKTREE}; skipping post-merge hook install"
    return 0
  fi

  # The .git inside a worktree is a file pointing to the real gitdir;
  # hooks live at <real-gitdir>/hooks/.
  local git_common
  git_common="$(git -C "${DEV_WORKTREE}" rev-parse --git-path hooks 2>/dev/null)" || {
    echo "⚠ could not resolve dev worktree git hooks dir; skipping post-merge hook install"
    return 0
  }
  # rev-parse returns a relative path; resolve to absolute.
  if [[ "$git_common" != /* ]]; then
    git_common="${DEV_WORKTREE}/${git_common}"
  fi

  if [[ ! -f "$HOOK_TEMPLATE" ]]; then
    echo "⚠ post-merge hook template not found at ${HOOK_TEMPLATE} (Phase DI-13); skipping"
    return 0
  fi

  mkdir -p "$git_common"
  cp "$HOOK_TEMPLATE" "${git_common}/post-merge"
  chmod +x "${git_common}/post-merge"
  echo "✓ post-merge hook installed at ${git_common}/post-merge"
}

case "$env_target" in
  --env=prod|prod)
    install_one esrd "${HOME}/.esrd" "${HOME}/Workspace/esr"
    ;;
  --env=dev|dev)
    ensure_dev_worktree
    install_one esrd-dev "${HOME}/.esrd-dev" "${DEV_WORKTREE}"
    install_dev_hook
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
