#!/usr/bin/env bash
# scripts/check-scenario-headers.sh — assert every e2e scenario
# declares its source guide via a `# Replays: docs/guides/<file>.md`
# header in its first 20 lines. See spec §3.4.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENARIO_DIR="${REPO_ROOT}/tests/e2e/scenarios"

# Exempt list: shared helpers + scenarios pending Phase 3 migration.
# Each entry removed as that scenario gets `# Replays:` header.
# Enumerate via:
#   ls tests/e2e/scenarios/ | awk -F_ '{print $1"_"}' | sort -u
# Phase 2 will remove `19_` from this list (the canary migration).
#
# Helpers (_common_selftest.sh, common.sh) take `\.` to require the literal
# `.sh` suffix; numbered scenarios take just the `NN_` prefix because their
# filenames vary (e.g. `01_single_user_create_and_end.sh`).
EXEMPT_REGEX='^(_common_selftest\.|common\.|01_|02_|04_|05_|06_|07_|08_|11_|14_|15_|16_|17_|18_|20_|21_|22_|23_|24_|25_|26_|27_|28_|29_|30_)'

fail=0
for f in "${SCENARIO_DIR}"/*.sh; do
  base="$(basename "${f}")"
  if [[ "${base}" =~ ${EXEMPT_REGEX} ]]; then
    continue
  fi
  header=$(head -20 "${f}")
  if ! grep -qE '^# Replays: docs/guides/[a-zA-Z0-9_-]+\.md' <<<"${header}"; then
    echo "FAIL: ${f} missing '# Replays: docs/guides/<file>.md' header (first 20 lines)" >&2
    fail=1
    continue
  fi
  guide=$(grep -oE 'docs/guides/[a-zA-Z0-9_-]+\.md' <<<"${header}" | head -1)
  if [[ ! -f "${REPO_ROOT}/${guide}" ]]; then
    echo "FAIL: ${f} references missing guide ${guide}" >&2
    fail=1
  fi
done

if [[ ${fail} -ne 0 ]]; then
  exit 1
fi
echo "check-scenario-headers: all scenarios have valid headers"
