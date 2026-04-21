#!/usr/bin/env bash
# scripts/esr-branch.sh — ephemeral esrd + git-worktree lifecycle.
#
# Called by Esr.Admin.Commands.Session.{New,End} via System.cmd/3 inside a
# Task so the Dispatcher isn't blocked. Prints a single JSON line to stdout.
#
# Usage:
#   esr-branch.sh new <branch_name> [--worktree-base=.claude/worktrees] [--repo-root=.]
#   esr-branch.sh end <branch_name> [--force] [--worktree-base=.claude/worktrees] [--repo-root=.]
#
# Branch name sanitization: `/` → `-` for all filesystem paths
# (worktree dir + ESRD_HOME suffix). The raw name is still used for the
# underlying git branch ref.
#
# JSON stdout contract:
#   new (ok):  {"ok":true,"branch":"feature-foo","branch_raw":"feature/foo",
#                "port":54321,"worktree_path":"/abs/path","esrd_home":"/tmp/esrd-feature-foo"}
#   new (err): {"ok":false,"error":"<reason>"}  -> exit 1
#   end (ok):  {"ok":true,"branch":"feature-foo"}
#   end (err): {"ok":false,"error":"<reason>"}  -> exit 1
#
# For tests, export ESRD_CMD_OVERRIDE (e.g. "sleep 60") so esrd.sh start
# doesn't actually launch mix phx.server. No dependency on the Elixir
# runtime for this script itself.
set -u

# --- resolve script dir (so we can call the sibling esrd.sh regardless
# --- of cwd) --------------------------------------------------------------
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
esrd_sh="$script_dir/esrd.sh"

# --- JSON emit helpers ---------------------------------------------------
json_escape() {
  # Escape \ and " for JSON string literals. Newlines are replaced by space
  # since our error messages are single-line anyway.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

emit_err() {
  local reason="$1"
  printf '{"ok":false,"error":"%s"}\n' "$(json_escape "$reason")"
  exit 1
}

# --- arg parsing ---------------------------------------------------------
sanitize_branch() {
  # `/` → `-` (most common), and defensively strip other path-dangerous
  # characters so ESRD_HOME and the worktree dir name are safe.
  local raw="$1"
  # shellcheck disable=SC2001
  echo "$raw" | sed 's|/|-|g'
}

parse_common_opts() {
  # Sets globals: worktree_base, repo_root, force
  worktree_base=".claude/worktrees"
  repo_root="."
  force="0"
  for arg in "$@"; do
    case "$arg" in
      --worktree-base=*) worktree_base="${arg#--worktree-base=}" ;;
      --repo-root=*)     repo_root="${arg#--repo-root=}" ;;
      --force)           force="1" ;;
    esac
  done
}

# --- `new` ---------------------------------------------------------------
cmd_new() {
  local branch_raw="${1:-}"
  shift || true
  [[ -z "$branch_raw" ]] && emit_err "missing branch_name"
  parse_common_opts "$@"

  local branch_sanitized
  branch_sanitized=$(sanitize_branch "$branch_raw")

  # Resolve absolute repo_root so downstream `git -C` + worktree paths are
  # stable regardless of caller cwd.
  local repo_abs
  if ! repo_abs=$(cd "$repo_root" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null); then
    emit_err "repo_root not a git repo: $repo_root"
  fi

  local worktree_path="$repo_abs/$worktree_base/$branch_sanitized"
  local esrd_home="/tmp/esrd-$branch_sanitized"

  # --- worktree creation ------------------------------------------------
  # Three cases:
  #   a) path already exists → reuse (idempotent new).
  #   b) branch ref exists but no worktree → `worktree add <path> <branch>`.
  #   c) neither → `worktree add <path> -b <branch>` (create branch).
  if [[ -d "$worktree_path" ]]; then
    : # reuse
  else
    mkdir -p "$(dirname "$worktree_path")"
    local add_out add_rc
    if git -C "$repo_abs" show-ref --verify --quiet "refs/heads/$branch_raw"; then
      add_out=$(git -C "$repo_abs" worktree add "$worktree_path" "$branch_raw" 2>&1)
      add_rc=$?
    else
      add_out=$(git -C "$repo_abs" worktree add "$worktree_path" -b "$branch_raw" 2>&1)
      add_rc=$?
    fi
    if (( add_rc != 0 )); then
      emit_err "git worktree add failed: $add_out"
    fi
  fi

  # --- start esrd -------------------------------------------------------
  mkdir -p "$esrd_home"
  local start_out start_rc
  start_out=$(ESRD_HOME="$esrd_home" ESR_REPO_DIR="$worktree_path" \
              bash "$esrd_sh" start --instance=default 2>&1)
  start_rc=$?
  if (( start_rc != 0 )); then
    emit_err "esrd start failed: $start_out"
  fi

  # --- wait up to 30 s for esrd.port -----------------------------------
  local port_file="$esrd_home/default/esrd.port"
  local waited=0
  while [[ ! -s "$port_file" ]] && (( waited < 300 )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [[ ! -s "$port_file" ]]; then
    emit_err "timeout waiting for $port_file"
  fi
  local port
  port=$(cat "$port_file")
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    emit_err "bad port value in $port_file: $port"
  fi

  # --- emit JSON --------------------------------------------------------
  printf '{"ok":true,"branch":"%s","branch_raw":"%s","port":%s,"worktree_path":"%s","esrd_home":"%s"}\n' \
    "$(json_escape "$branch_sanitized")" \
    "$(json_escape "$branch_raw")" \
    "$port" \
    "$(json_escape "$worktree_path")" \
    "$(json_escape "$esrd_home")"
}

# --- `end` ---------------------------------------------------------------
cmd_end() {
  local branch_raw="${1:-}"
  shift || true
  [[ -z "$branch_raw" ]] && emit_err "missing branch_name"
  parse_common_opts "$@"

  local branch_sanitized
  branch_sanitized=$(sanitize_branch "$branch_raw")

  local repo_abs
  if ! repo_abs=$(cd "$repo_root" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null); then
    emit_err "repo_root not a git repo: $repo_root"
  fi

  local worktree_path="$repo_abs/$worktree_base/$branch_sanitized"
  local esrd_home="/tmp/esrd-$branch_sanitized"

  # --- stop esrd (best-effort; ignore if nothing to stop) --------------
  if [[ -d "$esrd_home" ]]; then
    ESRD_HOME="$esrd_home" bash "$esrd_sh" stop --instance=default >/dev/null 2>&1 || true
    rm -rf "$esrd_home" 2>/dev/null || true
  fi

  # --- remove worktree --------------------------------------------------
  if [[ -d "$worktree_path" ]]; then
    local rm_out rm_rc
    if [[ "$force" == "1" ]]; then
      rm_out=$(git -C "$repo_abs" worktree remove --force "$worktree_path" 2>&1)
      rm_rc=$?
    else
      rm_out=$(git -C "$repo_abs" worktree remove "$worktree_path" 2>&1)
      rm_rc=$?
    fi
    if (( rm_rc != 0 )); then
      emit_err "git worktree remove failed: $rm_out"
    fi
  fi

  printf '{"ok":true,"branch":"%s"}\n' "$(json_escape "$branch_sanitized")"
}

# --- dispatch ------------------------------------------------------------
action="${1:-}"
shift || true
case "$action" in
  new) cmd_new "$@" ;;
  end) cmd_end "$@" ;;
  *)   emit_err "usage: $0 {new|end} <branch_name> [options]" ;;
esac
