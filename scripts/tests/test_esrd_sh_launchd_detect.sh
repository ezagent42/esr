#!/usr/bin/env bash
# Tests for the launchd-detection branch in scripts/esrd.sh cmd_stop
# (added 2026-05-10 to prevent the pidfile-stop / launchd-respawn race
# that produced 198 zombie BEAMs on the dev workstation).
#
# Strategy: shim `launchctl` and `HOME` so we can:
#   1. Simulate "plist installed AND launchd reports it loaded" → stop
#      must refuse (no kill, no pidfile delete) and print a pointer
#      to scripts/launchd/uninstall.sh.
#   2. Simulate the same + --launchd-restart → stop must invoke our
#      shimmed `launchctl kickstart -k gui/<uid>/com.ezagent.esrd-<i>`
#      and exit 0 without touching the pidfile.
#   3. Simulate "no plist" → falls through to existing pidfile path
#      (covered by sibling test_esrd_sh.sh; we re-assert one positive
#      case here for the no-launchd branch to keep this test
#      self-contained).
set -u

cd "$(git rev-parse --show-toplevel)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export ESRD_HOME="$tmp/.esrd"
export ESRD_CMD_OVERRIDE="sleep 60"

# Fake $HOME so the launchd-plist existence check sees what we want.
fake_home="$tmp/home"
mkdir -p "$fake_home/Library/LaunchAgents"

# Shim `launchctl` on PATH. The shim:
#   - prints a fake "list" line when invoked as `launchctl list`
#   - records `kickstart` invocations to a log file we can assert on
shim_dir="$tmp/bin"
mkdir -p "$shim_dir"
cat > "$shim_dir/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    if [[ -n "${SHIM_LAUNCHCTL_LIST_LABEL:-}" ]]; then
      echo "12345  0  ${SHIM_LAUNCHCTL_LIST_LABEL}"
    fi
    ;;
  kickstart)
    echo "$@" >> "${SHIM_LAUNCHCTL_LOG:-/dev/null}"
    ;;
esac
exit 0
LAUNCHCTL
chmod +x "$shim_dir/launchctl"
export PATH="$shim_dir:$PATH"

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
  fi
}

# -----------------------------------------------------------------
# Case 1: plist installed AND launchctl reports loaded → refuse stop
# -----------------------------------------------------------------
echo "=== case 1: launchd-managed, default stop refuses ==="
inst="ldetect1"
touch "$fake_home/Library/LaunchAgents/com.ezagent.esrd-${inst}.plist"
export SHIM_LAUNCHCTL_LIST_LABEL="com.ezagent.esrd-${inst}"
export SHIM_LAUNCHCTL_LOG="$tmp/launchctl-1.log"
: > "$SHIM_LAUNCHCTL_LOG"

# Pre-create a pidfile so we can verify cmd_stop doesn't delete it.
mkdir -p "$ESRD_HOME/$inst"
echo "99999" > "$ESRD_HOME/$inst/esrd.pid"

out=$(HOME="$fake_home" bash scripts/esrd.sh stop --instance="$inst" 2>&1)
echo "[output] $out"

check "output identifies instance as launchd-managed"   "echo '$out' | grep -q 'launchd-managed'"
check "output points at scripts/launchd/uninstall.sh"   "echo '$out' | grep -q 'scripts/launchd/uninstall.sh'"
check "output mentions launchctl kickstart hint"        "echo '$out' | grep -q 'launchctl kickstart'"
check "pidfile NOT deleted (refused, did not act)"      "[[ -f $ESRD_HOME/$inst/esrd.pid ]]"
check "kickstart NOT invoked without --launchd-restart" "[[ ! -s $SHIM_LAUNCHCTL_LOG ]]"

# -----------------------------------------------------------------
# Case 2: --launchd-restart → delegates to launchctl kickstart -k
# -----------------------------------------------------------------
echo
echo "=== case 2: launchd-managed + --launchd-restart delegates ==="
out2=$(HOME="$fake_home" bash scripts/esrd.sh stop --instance="$inst" --launchd-restart 2>&1)
echo "[output] $out2"

check "output reports kickstart success"             "echo '$out2' | grep -q 'launchctl kickstart -k'"
check "kickstart WAS invoked"                         "[[ -s $SHIM_LAUNCHCTL_LOG ]]"
check "kickstart args include -k flag"                "grep -q '\\-k' $SHIM_LAUNCHCTL_LOG"
check "kickstart args include the right label"        "grep -q 'com.ezagent.esrd-${inst}' $SHIM_LAUNCHCTL_LOG"
check "pidfile still NOT deleted (launchd path)"      "[[ -f $ESRD_HOME/$inst/esrd.pid ]]"

# -----------------------------------------------------------------
# Case 3: no plist → falls through to pidfile-based stop
# -----------------------------------------------------------------
echo
echo "=== case 3: no plist → pidfile path still works ==="
inst2="ldetect2"
unset SHIM_LAUNCHCTL_LIST_LABEL  # launchctl list returns empty
# No plist file for inst2.
HOME="$fake_home" bash scripts/esrd.sh start --instance="$inst2" >/dev/null
check "pidfile created on start"                "[[ -s $ESRD_HOME/$inst2/esrd.pid ]]"
HOME="$fake_home" bash scripts/esrd.sh stop --instance="$inst2" >/dev/null
check "pidfile removed by stop (no plist path)" "[[ ! -f $ESRD_HOME/$inst2/esrd.pid ]]"

# -----------------------------------------------------------------
# Case 4: plist file present BUT launchctl list returns empty →
# fall through (operator manually `bootout`-ed but didn't `rm`)
# -----------------------------------------------------------------
echo
echo "=== case 4: stale plist (file exists, not loaded) → pidfile path ==="
inst3="ldetect3"
touch "$fake_home/Library/LaunchAgents/com.ezagent.esrd-${inst3}.plist"
unset SHIM_LAUNCHCTL_LIST_LABEL
HOME="$fake_home" bash scripts/esrd.sh start --instance="$inst3" >/dev/null
check "pidfile created on start"                       "[[ -s $ESRD_HOME/$inst3/esrd.pid ]]"
HOME="$fake_home" bash scripts/esrd.sh stop --instance="$inst3" >/dev/null
check "stale plist alone does NOT trigger refusal"     "[[ ! -f $ESRD_HOME/$inst3/esrd.pid ]]"

echo
if (( fail == 0 )); then
  echo "ALL $pass esrd.sh launchd-detect tests PASSED"
else
  echo "$fail failures out of $((pass + fail)) tests"
  exit 1
fi
