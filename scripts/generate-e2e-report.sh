#!/usr/bin/env bash
# scripts/generate-e2e-report.sh — local e2e report generator.
# See docs/superpowers/specs/2026-05-10-guide-driven-e2e.md §3.7.
#
# For each fenced guide in docs/guides/, runs scripts/replay-guide.sh
# and accumulates results. Writes docs/e2e-reports/<short-sha>.md
# referencing the current HEAD commit. Commit this file to satisfy
# CI's verify-e2e-report.sh gate.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SHORT_SHA=$(git rev-parse --short=8 HEAD)
FULL_SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUN_BY=$(git config user.email || echo "unknown")
REPORT_DIR="docs/e2e-reports"
REPORT="${REPORT_DIR}/${SHORT_SHA}.md"

mkdir -p "${REPORT_DIR}"

# Collect guides: _replay_smoke.md + every flow-*.md that has chat-input fences.
guides=()
guides+=("docs/guides/_replay_smoke.md")
for guide in docs/guides/flow-*.md; do
  [[ -f "${guide}" ]] || continue
  if grep -q '^```chat-input' "${guide}"; then
    guides+=("${guide}")
  fi
done

declare -a results
overall_pass=1

for guide in "${guides[@]}"; do
  base=$(basename "${guide}")
  echo ">>> ${base}" >&2
  start=$(date +%s)
  set +e
  out=$(bash scripts/replay-guide.sh "${guide}" 2>&1)
  rc=$?
  set -e
  end=$(date +%s)
  elapsed=$((end - start))
  wall="${elapsed}s"

  # Extract step count from the script's summary line, which has the form
  # "<path>: N step(s) replayed, PASS" OR "<path>: N step(s) passed, FAIL at ...".
  # The teardown trap in common.sh appends extra lines after, so grep
  # for the pattern rather than `tail -1`.
  summary=$(printf '%s\n' "${out}" | grep -E 'step\(s\) (replayed|passed)' | tail -1 || true)
  steps=$(printf '%s' "${summary}" | grep -oE '[0-9]+ step' | head -1 | awk '{print $1}')
  steps="${steps:-?}"

  if [[ "${rc}" -eq 0 ]]; then
    status="PASS"
  else
    status="FAIL"
    overall_pass=0
  fi

  results+=("| ${base} | ${status} | ${steps} | ${wall} |")
  echo "  ${status} (${steps} steps, ${wall})" >&2
done

# Write the report.
{
  printf '# E2E report — %s\n\n' "${FULL_SHA}"
  printf -- '- Generated: %s\n' "${TIMESTAMP}"
  printf -- '- Branch: %s\n' "${BRANCH}"
  printf -- '- Run by: %s\n\n' "${RUN_BY}"
  printf '## Results\n\n'
  printf '| Guide | Status | Steps | Wall time |\n'
  printf '|---|---|---|---|\n'
  for row in "${results[@]}"; do
    printf '%s\n' "${row}"
  done
  printf '\n## Overall\n\n'
  if [[ "${overall_pass}" -eq 1 ]]; then
    printf 'PASS — %d/%d guides\n' "${#guides[@]}" "${#guides[@]}"
  else
    fail_count=0
    for row in "${results[@]}"; do
      [[ "${row}" == *"| FAIL |"* ]] && fail_count=$((fail_count + 1))
    done
    pass_count=$((${#guides[@]} - fail_count))
    printf 'FAIL — %d/%d guides passed\n' "${pass_count}" "${#guides[@]}"
  fi
} > "${REPORT}"

echo ""
echo "wrote ${REPORT}"
if [[ "${overall_pass}" -eq 1 ]]; then
  echo "overall: PASS"
  exit 0
else
  echo "overall: FAIL (re-run after fixing the failing guides; do NOT commit a failing report)" >&2
  exit 1
fi
