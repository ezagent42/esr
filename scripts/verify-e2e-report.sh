#!/usr/bin/env bash
# scripts/verify-e2e-report.sh — CI anti-drift gate (report-based).
# See docs/superpowers/specs/2026-05-10-guide-driven-e2e.md §3.7.
#
# Enforces: if this PR touches command handlers or fenced flow guides,
# docs/e2e-reports/<short-sha>.md must exist for HEAD, reference HEAD's
# full sha, and show all guides PASS. Otherwise the e2e is stale or skipped.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Diff target: GH Actions PR runs use GITHUB_BASE_REF; pushes / local use dev.
# ESR convention: feature PRs target dev; dev cherry-picks to main on release.
BASE_REF="${GITHUB_BASE_REF:-dev}"
DIFF_BASE="origin/${BASE_REF}"
git fetch --no-tags origin "${BASE_REF}" >/dev/null 2>&1 || true

# Find the latest non-merge commit in the PR that touches command handlers
# or fenced flow guides. That commit is what the e2e report must reference.
# Commits AFTER it (typically the report commit itself, or unrelated
# cleanup) do not invalidate the report.
#
# Using `git log -- <paths>` avoids the chicken-and-egg of "the report
# referencing its own commit hash" — the report is allowed to live in a
# commit AFTER the relevant code commit.
#
# `--no-merges` skips the merge commit that GH Actions checkout creates
# (refs/pull/<n>/merge); its diff against the PR's base ref looks like it
# touches every modified file in the PR, which would always trigger the
# report requirement even on PRs that don't change relevant paths.
TARGET_SHA=$(git log --reverse --no-merges --format=%H "${DIFF_BASE}..HEAD" \
              -- runtime/lib/esr/commands/ 'docs/guides/flow-*.md' \
              2>/dev/null | tail -1)

if [[ -z "${TARGET_SHA}" ]]; then
  echo "verify-e2e-report: PR does not touch command handlers or fenced guides; skipping."
  exit 0
fi

TARGET_SHORT=$(git rev-parse --short=8 "${TARGET_SHA}")
REPORT="docs/e2e-reports/${TARGET_SHORT}.md"

if [[ ! -f "${REPORT}" ]]; then
  echo "FAIL: ${REPORT} is missing." >&2
  echo "" >&2
  echo "The latest commit in this PR that touches command handlers or" >&2
  echo "fenced flow guides is ${TARGET_SHA}." >&2
  echo "The anti-drift gate requires an e2e report for that commit." >&2
  echo "" >&2
  echo "Run locally and commit the result:" >&2
  echo "  git checkout ${TARGET_SHA}     # check out the target commit" >&2
  echo "  bash scripts/generate-e2e-report.sh" >&2
  echo "  git checkout -                 # return to your branch" >&2
  echo "  git cherry-pick (or apply) the generated ${REPORT}" >&2
  echo "" >&2
  echo "Simpler: amend the target commit OR run the script at the tip" >&2
  echo "of your branch and commit the result; the verifier checks the" >&2
  echo "latest relevant commit's report, not the tip." >&2
  exit 1
fi

if ! grep -q "${TARGET_SHA}" "${REPORT}"; then
  echo "FAIL: ${REPORT} does not reference commit ${TARGET_SHA}." >&2
  echo "The report's hash must match the latest commit in this PR" >&2
  echo "touching command handlers or fenced guides. Re-run" >&2
  echo "scripts/generate-e2e-report.sh and commit the new report." >&2
  exit 1
fi

if grep -qE '\| FAIL ' "${REPORT}"; then
  echo "FAIL: ${REPORT} shows failing guides:" >&2
  grep -E '\| FAIL ' "${REPORT}" >&2
  exit 1
fi

echo "verify-e2e-report: PASS (report ${REPORT} verified for target commit ${TARGET_SHA})"
