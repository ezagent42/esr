#!/usr/bin/env bash
# scenario 19 — session-first default workspace resolution.
#
# Replays: docs/guides/flow-bootstrap.md
#
# This script is a thin wrapper around scripts/replay-guide.sh. The
# real test lives in the guide's fences. Edit the guide, not this file.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

exec bash "${SCRIPT_DIR}/../../../scripts/replay-guide.sh" \
  "${SCRIPT_DIR}/../../../docs/guides/flow-bootstrap.md"
