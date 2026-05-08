#!/usr/bin/env bash
# Ralph-loop v2 per-iteration anti-tamper orchestrator (spec §4.3).
# Runs all 11 LG-* checks. Bails on the first failure.
set -u

cd "$(git rev-parse --show-toplevel)" || { echo "not in a git repo"; exit 2; }

pass=0

check() {
  local id="$1"; shift
  local msg="$1"; shift
  echo "[$id] $msg" >&2
  if "$@" >/tmp/loopguard.$$.out 2>&1; then
    pass=$((pass + 1))
  else
    cat /tmp/loopguard.$$.out >&2
    rm -f /tmp/loopguard.$$.out
    echo "loopguard FAIL — $id — $msg"
    echo "<promise>BLOCKED: loopguard:$id</promise>"
    exit 1
  fi
  rm -f /tmp/loopguard.$$.out
}

# LG-1 ("scenario YAML well-formed + live-signature") removed
# 2026-05-06 — scenarios/ deleted in scenarios+python-cli-removal
# PR. The check existed only to gate scenarios/*.yaml shape; the
# tests/e2e/ bash scripts at PR-7+ era are the live e2e harness now.

check LG-2  "no soft stubs in entry bodies"  \
    uv run --project py python scripts/verify_entry_bodies.py

check LG-3  "no deferral phrases in PRD acceptance"  \
    uv run --project py python scripts/verify_prd_acceptance.py --regex-scan

check LG-4  "final_gate.sh SHA pin"  \
    sha256sum -c scripts/final_gate.sh.sha256

check LG-5  "acceptance manifest match + ticked"  \
    uv run --project py python scripts/verify_prd_acceptance.py \
        --manifest docs/superpowers/prds/acceptance-manifest.yaml

# LG-6 ("scenarios/ allowlist") removed 2026-05-06 — scenarios/
# directory deleted. Adding new e2e scenarios goes through
# tests/e2e/scenarios/*.sh which has its own conventions.

check LG-7  "ledger append-only + enum"  \
    uv run --project py python scripts/verify_ledger_append_only.py

check LG-8  "no new @pytest.mark.skip/xfail since baseline"  \
    bash -c '
      baseline=$(cat .ralph-loop-baseline 2>/dev/null || echo HEAD)
      diff_out=$(git diff "$baseline" -- "py/tests" "runtime/test" 2>/dev/null || true)
      if echo "$diff_out" | grep -qE "^\+.*(@pytest\.mark\.(skip|xfail)|@tag.*:skip)"; then
        exit 1
      fi
      exit 0
    '

check LG-9  "CLI tests use esrd_fixture"  \
    uv run --project py python scripts/verify_cli_tests_live.py

check LG-10 "no _submit_* monkeypatch in tests"  \
    uv run --project py python scripts/verify_cli_tests_live.py --no-monkeypatch

check LG-11 "loopguard bundle SHA pin"  \
    sha256sum -c scripts/loopguard-bundle.sha256

echo "all $pass loopguard checks passed"
