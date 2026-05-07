#!/usr/bin/env bash
# Smoke test for tools/wipe-esrd-home.sh — verifies dry-run exits 0 + prints target,
# and that files are NOT deleted in dry-run mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIPE_SCRIPT="${SCRIPT_DIR}/wipe-esrd-home.sh"

[[ -f "$WIPE_SCRIPT" ]] || { echo "FAIL: wipe-esrd-home.sh not found"; exit 1; }
[[ -x "$WIPE_SCRIPT" ]] || { echo "FAIL: wipe-esrd-home.sh not executable"; exit 1; }

# --- Test 1: dry-run must not delete files and must print target path ---
TMP_HOME="$(mktemp -d /tmp/wipe-esrd-test-XXXXXX)"
touch "${TMP_HOME}/sentinel"

OUTPUT=$(ESRD_HOME="$TMP_HOME" bash "$WIPE_SCRIPT" --dry-run --dev 2>&1)
echo "[dry-run output] $OUTPUT"

[[ -f "${TMP_HOME}/sentinel" ]] || { echo "FAIL: dry-run deleted files"; exit 1; }
echo "$OUTPUT" | grep -q "$TMP_HOME" || { echo "FAIL: dry-run did not print target path"; exit 1; }

rm -rf "$TMP_HOME"

# --- Test 2: wipe mode deletes directory contents but preserves the dir ---
TMP_HOME2="$(mktemp -d /tmp/wipe-esrd-test-XXXXXX)"
mkdir -p "${TMP_HOME2}/sessions/abc"
touch "${TMP_HOME2}/sessions/abc/state.yaml"
touch "${TMP_HOME2}/workspaces.yaml"

# Pass "yes" to the confirmation prompt via stdin.
OUTPUT2=$(echo "yes" | ESRD_HOME="$TMP_HOME2" bash "$WIPE_SCRIPT" --dev 2>&1)
echo "[wipe output] $OUTPUT2"

# Directory must still exist.
[[ -d "$TMP_HOME2" ]] || { echo "FAIL: wipe removed the directory itself"; exit 1; }

# Contents must be gone.
remaining=$(find "$TMP_HOME2" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
[[ "$remaining" -eq 0 ]] || { echo "FAIL: wipe left ${remaining} item(s) in ${TMP_HOME2}"; exit 1; }

rm -rf "$TMP_HOME2"

# --- Test 3: wipe aborted when confirmation is 'no' ---
TMP_HOME3="$(mktemp -d /tmp/wipe-esrd-test-XXXXXX)"
touch "${TMP_HOME3}/sentinel3"

echo "no" | ESRD_HOME="$TMP_HOME3" bash "$WIPE_SCRIPT" --dev 2>&1 || true
[[ -f "${TMP_HOME3}/sentinel3" ]] || { echo "FAIL: abort path deleted files on 'no' input"; exit 1; }

rm -rf "$TMP_HOME3"

echo "PASS: wipe-esrd-home_test.sh"
