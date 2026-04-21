#!/usr/bin/env bash
# Tests for scripts/esr-branch.sh. Follows test_esrd_sh_port.sh pattern:
# spin up a scratch git repo in a tmpdir, exercise new/end, verify JSON
# contract + side effects. ESRD_CMD_OVERRIDE='sleep 60' keeps esrd.sh
# from actually booting mix phx.server.
set -u

# The script should be invokable from anywhere; we use absolute paths.
repo_scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
branch_sh="$repo_scripts_dir/esr-branch.sh"

tmp=$(mktemp -d)
# Scratch git repo we can `git worktree add` inside without affecting the
# real esr checkout. /tmp cleanup + esrd stop handled by trap.
scratch_repo="$tmp/scratch"

cleanup() {
  # Kill anything we spawned; remove ephemeral ESRD_HOME dirs we created.
  for d in "$tmp"/esrd-home-*; do
    [[ -d "$d" ]] || continue
    if [[ -s "$d/default/esrd.pid" ]]; then
      pid=$(cat "$d/default/esrd.pid")
      kill "$pid" 2>/dev/null || true
    fi
  done
  # The script uses /tmp/esrd-<branch>; clean those for our test branches.
  for d in /tmp/esrd-testnew-* /tmp/esrd-feature-testing /tmp/esrd-existing-branch; do
    [[ -d "$d" ]] || continue
    if [[ -s "$d/default/esrd.pid" ]]; then
      pid=$(cat "$d/default/esrd.pid")
      kill "$pid" 2>/dev/null || true
    fi
    rm -rf "$d" 2>/dev/null || true
  done
  # esrd.sh daemonizes via a subshell; on stop, SIGTERM reaches the
  # subshell pid but the reparented `sleep` grandchild survives as an
  # orphan (ppid=1). We don't force-kill those here (too risky —
  # could match unrelated user sleeps); the short duration in
  # ESRD_CMD_OVERRIDE keeps them from lingering.
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

pass=0
fail=0
check() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
    echo "  ok — $desc"
  else
    fail=$((fail + 1))
    echo "  FAIL — $desc"
    echo "    cond: $cond"
  fi
}

# --- scratch repo setup --------------------------------------------------
# We need a real git repo so `git worktree add` works. Use main as default.
mkdir -p "$scratch_repo"
(
  cd "$scratch_repo"
  git init -q -b main
  git config user.email test@example.com
  git config user.name  Tester
  echo hello > README.md
  git add README.md
  git commit -q -m 'init'
) || { echo "FAIL — could not set up scratch repo"; exit 1; }

# The test esr-branch.sh needs esrd.sh right next to it. The production
# esrd.sh is at $repo_scripts_dir/esrd.sh — we keep that, but tell both
# scripts to use a sandboxed ESRD_HOME by calling through our wrapper
# env. esrd.sh uses ESRD_CMD_OVERRIDE so the "server" is a trivial
# `sleep` stand-in. We use `sleep 30` (not 60) so any grandchild-reparented
# process that escapes esrd.sh stop (parent subshell exits and SIGTERM
# reaches the intermediate pid only, a known quirk of the current
# esrd.sh daemonization) dies within a minute — keeps the process table
# tidy for repeated local runs without affecting CI correctness.
export ESRD_CMD_OVERRIDE='sleep 30'

# === Scenario 1: new a fresh branch ======================================
echo "=== 1) new (fresh branch) ==="
out1=$(bash "$branch_sh" new "testnew-one" \
         --worktree-base=wt --repo-root="$scratch_repo")
rc1=$?
check "scenario 1 exit code 0"     "(( $rc1 == 0 ))"
check "scenario 1 JSON ok=true"    "echo '$out1' | grep -q '\"ok\":true'"
check "scenario 1 JSON has branch" "echo '$out1' | grep -q '\"branch\":\"testnew-one\"'"
check "scenario 1 JSON has port"   "echo '$out1' | grep -qE '\"port\":[0-9]+'"
check "scenario 1 worktree dir"    "[[ -d \"$scratch_repo/wt/testnew-one\" ]]"
check "scenario 1 esrd.port file"  "[[ -s /tmp/esrd-testnew-one/default/esrd.port ]]"
check "scenario 1 esrd.pid file"   "[[ -s /tmp/esrd-testnew-one/default/esrd.pid ]]"

# === Scenario 2: end the branch =========================================
echo "=== 2) end ==="
out2=$(bash "$branch_sh" end "testnew-one" \
         --worktree-base=wt --repo-root="$scratch_repo")
rc2=$?
check "scenario 2 exit code 0"     "(( $rc2 == 0 ))"
check "scenario 2 JSON ok=true"    "echo '$out2' | grep -q '\"ok\":true'"
check "scenario 2 worktree gone"   "[[ ! -d \"$scratch_repo/wt/testnew-one\" ]]"
check "scenario 2 esrd_home gone"  "[[ ! -d /tmp/esrd-testnew-one ]]"

# === Scenario 3: new with slash-sanitization + existing git branch =======
echo "=== 3) new (slash-sanitization + existing branch) ==="
# Pre-create a real git branch, then invoke `new` with its raw name.
# The script should see the branch exists, create a worktree pointing
# at it, and sanitize `feature/testing` → `feature-testing` for paths.
(
  cd "$scratch_repo"
  git branch feature/testing
)
out3=$(bash "$branch_sh" new "feature/testing" \
         --worktree-base=wt --repo-root="$scratch_repo")
rc3=$?
check "scenario 3 exit code 0"                 "(( $rc3 == 0 ))"
check "scenario 3 JSON ok=true"                "echo '$out3' | grep -q '\"ok\":true'"
check "scenario 3 JSON sanitized branch"       "echo '$out3' | grep -q '\"branch\":\"feature-testing\"'"
check "scenario 3 JSON branch_raw preserved"   "echo '$out3' | grep -q '\"branch_raw\":\"feature/testing\"'"
check "scenario 3 worktree dir sanitized"      "[[ -d \"$scratch_repo/wt/feature-testing\" ]]"
check "scenario 3 esrd_home sanitized"         "[[ -d /tmp/esrd-feature-testing ]]"

# === Scenario 4: new on an already-spawned branch fails cleanly =========
# The worktree dir already exists from scenario 3. Running `new` again
# on the same raw branch name is idempotent at the worktree level (we
# reuse the existing directory) and at the esrd level (esrd.sh start is
# idempotent if pid is alive). So this scenario verifies re-entry
# returns ok=true, not a failure — per Task 19 step 3 "Verify idempotency".
echo "=== 4) new (idempotent re-entry) ==="
out4=$(bash "$branch_sh" new "feature/testing" \
         --worktree-base=wt --repo-root="$scratch_repo")
rc4=$?
check "scenario 4 exit code 0"           "(( $rc4 == 0 ))"
check "scenario 4 JSON ok=true"          "echo '$out4' | grep -q '\"ok\":true'"
check "scenario 4 still one pid"         "[[ -s /tmp/esrd-feature-testing/default/esrd.pid ]]"

# === Scenario 5: new against a non-git repo_root emits JSON error =======
echo "=== 5) new (invalid repo_root → ok:false) ==="
non_repo="$tmp/not-a-repo"
mkdir -p "$non_repo"
out5=$(bash "$branch_sh" new "whatever" \
         --worktree-base=wt --repo-root="$non_repo" 2>&1)
rc5=$?
check "scenario 5 exit code 1"        "(( $rc5 == 1 ))"
check "scenario 5 JSON ok=false"      "echo '$out5' | grep -q '\"ok\":false'"
check "scenario 5 JSON has error"     "echo '$out5' | grep -q '\"error\":'"

# === Cleanup: end feature/testing so we leave no stray state ============
bash "$branch_sh" end "feature/testing" --worktree-base=wt --repo-root="$scratch_repo" >/dev/null 2>&1 || true

echo
if (( fail == 0 )); then
  echo "ALL $pass esr-branch.sh tests PASSED"
else
  echo "$fail failures out of $((pass + fail)) tests"
  exit 1
fi
