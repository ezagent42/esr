#!/bin/bash
set -euo pipefail

# Refresh Skill 1's module index — and, when the test baseline has drifted,
# rebuild that too.
#
# Called in three very different situations, so the flags are orthogonal:
#
#   --all              rescan manifest.json + re-run every test-runner
#   --module <name>    re-run one module's test-runner (fast path)
#   --with-baseline    rebuild bootstrap/test-baseline.json (slow; runs full tests)
#
# Typical triggers:
#   - indexed file path no longer exists (moved/renamed/deleted)
#   - test-runner fails with an unexpected error (command outdated)
#   - new module appeared that isn't in the index yet
#   - post-merge hook on main wants to keep the baseline honest

DRY_RUN=false
MODULE=""
ALL=false
WITH_BASELINE=false
PROJECT_ROOT=""

# Pick the newest installed copy of the dev-loop-skills plugin — that's
# where scan-project.sh and run-full-tests.sh live. The glob is version-
# agnostic so projects keep working across plugin upgrades.
find_plugin_scripts() {
    local candidate
    for candidate in ~/.claude/plugins/cache/ezagent42/dev-loop-skills/*/skills/skill-0-project-builder/scripts; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--module <name>] [--all] [--with-baseline] [--project-root <path>] [--dry-run] [--help]

Refresh Skill 1 module index — optionally rebuild the test baseline too.

Options:
  --module <name>     Refresh a single module (runs test-<name>.sh)
  --all               Rescan manifest.json + re-run every test-runner
  --with-baseline     Rebuild .artifacts/bootstrap/test-baseline.json
                      (runs full test suite; requires dev-loop-skills plugin)
  --project-root <p>  Override project root (default: git toplevel of CWD)
  --dry-run           Show what would happen; make no changes
  --help              Show this help

At least one of --module, --all, or --with-baseline must be given. They
can be combined; the post-merge hook uses '--all --with-baseline'.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module) MODULE="$2"; shift 2 ;;
        --all) ALL=true; shift ;;
        --with-baseline) WITH_BASELINE=true; shift ;;
        --project-root) PROJECT_ROOT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) usage ;;
        *) echo "Error: unknown option '$1'. Use --help for usage." >&2; exit 1 ;;
    esac
done

if [[ -z "$MODULE" && "$ALL" != "true" && "$WITH_BASELINE" != "true" ]]; then
    echo "Error: specify at least one of --module <name>, --all, or --with-baseline." >&2
    exit 1
fi

if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "Error: project root not found: $PROJECT_ROOT" >&2
    exit 1
fi

ARTIFACTS="$PROJECT_ROOT/.artifacts"

# Plugin lookup is lazy — we only need it for --all (manifest rescan) or
# --with-baseline (full-tests rerun). Module-only refresh is self-contained
# in the sibling test-<module>.sh scripts, so it doesn't need the plugin.
PLUGIN_SCRIPTS=""
if $ALL || $WITH_BASELINE; then
    if ! PLUGIN_SCRIPTS=$(find_plugin_scripts); then
        if $WITH_BASELINE; then
            echo "Error: --with-baseline needs dev-loop-skills plugin at ~/.claude/plugins/cache/ezagent42/dev-loop-skills/*/" >&2
            echo "       Install via the Claude Code marketplace, then re-run." >&2
            exit 1
        fi
        echo "[warn] dev-loop-skills plugin not found; skipping manifest rescan (test-runners will still run)" >&2
    fi
fi

if $DRY_RUN; then
    echo "[dry-run] Project: $PROJECT_ROOT"
    $ALL && echo "[dry-run] Would rescan manifest.json and run all test-runners"
    [[ -n "$MODULE" ]] && echo "[dry-run] Would run test-runner for module: $MODULE"
    $WITH_BASELINE && echo "[dry-run] Would rebuild test-baseline.json via $PLUGIN_SCRIPTS/run-full-tests.sh"
    exit 0
fi

echo "=== Skill 1 Index Refresh ==="
echo "Project: $PROJECT_ROOT"

if $ALL; then
    echo "Scope: all modules"

    if [[ -n "$PLUGIN_SCRIPTS" ]]; then
        echo "Rescanning manifest.json via scan-project.sh…"
        bash "$PLUGIN_SCRIPTS/scan-project.sh" \
            --project-root "$PROJECT_ROOT" \
            --output "$ARTIFACTS/bootstrap/manifest.json"
    fi

    echo "Re-running test-runners…"
    for runner in "$(dirname "$0")"/test-*.sh; do
        [[ -f "$runner" ]] || continue
        name=$(basename "$runner")
        # Skip the aggregator — it would re-invoke every sibling and double the work.
        [[ "$name" == "test-all.sh" ]] && continue
        printf "  %-40s " "$name"
        if bash "$runner" > /dev/null 2>&1; then
            echo "PASS"
        else
            echo "FAIL (test-runner may need updating)"
        fi
    done
elif [[ -n "$MODULE" ]]; then
    echo "Scope: module '$MODULE'"
    RUNNER="$(dirname "$0")/test-${MODULE}.sh"
    if [[ -f "$RUNNER" ]]; then
        echo "Running test-${MODULE}.sh…"
        bash "$RUNNER" && echo "  → PASS" || echo "  → FAIL"
    else
        echo "No test-runner found for module '$MODULE'."
        echo "Consider creating scripts/test-${MODULE}.sh"
        exit 1
    fi
fi

if $WITH_BASELINE; then
    echo
    echo "Rebuilding test-baseline.json via run-full-tests.sh…"
    bash "$PLUGIN_SCRIPTS/run-full-tests.sh" \
        --project-root "$PROJECT_ROOT" \
        --output "$ARTIFACTS/bootstrap/test-baseline.json"
fi

echo
echo "Index refresh complete."
echo "Note: SKILL.md module index may need a manual edit if modules were added or removed."
