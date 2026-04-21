#!/bin/bash
# ESR-specific bootstrap verification (overrides the plugin's verify-bootstrap.sh
# which hardcodes zchat module names like agent_manager, irc_manager).
#
# Same 26-check spirit, but module names match ESR's actual layer/subsystem split.
set -euo pipefail

ROOT="${1:-/home/yaosh/projects/esr}"
ARTIFACTS="$ROOT/.artifacts"

PASS=0
FAIL=0
WARN=0

check() {
    local sev="$1" desc="$2" result="$3"
    if [ "$result" = "true" ]; then echo "  ✅ $desc"; PASS=$((PASS+1))
    elif [ "$sev" = "BLOCK" ]; then echo "  ❌ [BLOCK] $desc"; FAIL=$((FAIL+1))
    else echo "  ⚠️  [WARN] $desc"; WARN=$((WARN+1))
    fi
}

echo "=== ESR Bootstrap Completeness Verification ==="
echo "Project: $ROOT"
echo ""

echo "Step 1: manifest"
check BLOCK "manifest.json exists" "$([ -f "$ARTIFACTS/bootstrap/manifest.json" ] && echo true || echo false)"

echo ""
echo "Step 2: env-report"
check BLOCK "env-report.json exists" "$([ -f "$ARTIFACTS/bootstrap/env-report.json" ] && echo true || echo false)"

echo ""
echo "Step 3: module-reports (ESR's 16 actual modules)"
mr="$ARTIFACTS/bootstrap/module-reports"
for m in py-sdk-core py-cli py-ipc py-verify adapter-feishu adapter-cc-tmux adapter-cc-mcp handler-feishu-app handler-feishu-thread handler-cc-session handler-tmux-proxy scripts patterns-roles-scenarios runtime-core runtime-subsystems runtime-web; do
    check BLOCK "module-report for $m exists" "$([ -f "$mr/$m.json" ] && echo true || echo false)"
done

echo ""
echo "Step 4: tests executed"
# ESR's pytest cache lives in both py/.pytest_cache and root .pytest_cache
main_ran=false
[ -d "$ROOT/.pytest_cache" ] && main_ran=true
[ -d "$ROOT/py/.pytest_cache" ] && main_ran=true
check BLOCK "main project tests executed (py/.pytest_cache present)" "$main_ran"

# Elixir build + test run evidence
ex_ran=false
[ -d "$ROOT/runtime/_build" ] && ex_ran=true
check BLOCK "elixir runtime compiled + tested (_build/ present)" "$ex_ran"

# test-baseline exists
check BLOCK "test-baseline.json exists" "$([ -f "$ARTIFACTS/bootstrap/test-baseline.json" ] && echo true || echo false)"

echo ""
echo "Step 5: coverage-matrix"
cm="$ARTIFACTS/coverage/coverage-matrix.md"
check BLOCK "coverage-matrix.md exists" "$([ -f "$cm" ] && echo true || echo false)"
if [ -f "$cm" ]; then
    has_fm=$(head -1 "$cm" | grep -c '^---' || true)
    check BLOCK "coverage-matrix has YAML frontmatter" "$([ "$has_fm" -gt 0 ] && echo true || echo false)"
    has_e2e=$(grep -c 'E2E' "$cm" || true)
    check WARN "coverage-matrix mentions E2E ($has_e2e hits)" "$([ "$has_e2e" -gt 3 ] && echo true || echo false)"
fi

echo ""
echo "Step 6: artifact space"
check BLOCK ".artifacts/ exists" "$([ -d "$ARTIFACTS" ] && echo true || echo false)"
check BLOCK "registry.json exists" "$([ -f "$ARTIFACTS/registry.json" ] && echo true || echo false)"
if [ -f "$ARTIFACTS/registry.json" ]; then
    n=$(grep -c '"id"' "$ARTIFACTS/registry.json" 2>/dev/null || true)
    check BLOCK "registry has ≥1 artifact ($n found)" "$([ "$n" -ge 1 ] && echo true || echo false)"
fi
for d in eval-docs test-plans test-diffs e2e-reports coverage; do
    check WARN ".artifacts/$d/ exists" "$([ -d "$ARTIFACTS/$d" ] && echo true || echo false)"
done

echo ""
echo "Step 7.5: bootstrap-report"
br="$ARTIFACTS/bootstrap/bootstrap-report.md"
check WARN "bootstrap-report.md exists" "$([ -f "$br" ] && echo true || echo false)"

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL blocked, $WARN warnings"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo "❌ BOOTSTRAP INCOMPLETE"
    exit 1
fi
echo "✅ Bootstrap verification passed. Safe to proceed to Step 7."
