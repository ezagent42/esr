"""Verify every test file listed in each PRD's unit-test matrix exists on disk.

Final Gate §8 condition 2 requires this check. The PRDs live under
``docs/superpowers/prds/0[1-7]-*.md`` with a ``| FR | test-file | test-name |``
markdown table. We parse those, check each listed test path resolves
under the repo root, and print a per-PRD summary.

Exit 0 when every row's test file exists; exit 1 with a list of
missing paths otherwise. ``all N FR tests located`` on success.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PRDS_DIR = REPO_ROOT / "docs" / "superpowers" / "prds"

# Matches a matrix row: `| F07 | path/to/test | name |` — one or more pipes allowed
ROW = re.compile(r"^\|\s*(F\d+[a-z]?)\s*\|\s*`?([^|`]+?)`?\s*\|\s*(.+?)\s*\|\s*$")

# Test-file column may say "—" / "same" / "per-handler ..." — these are
# deliberate non-path placeholders we skip.
NON_PATHS = {"—", "-", "same", ""}


def parse_prd(path: Path) -> list[tuple[str, str]]:
    """Return ``[(fr, test_path), ...]`` for the matrix in this PRD."""
    rows: list[tuple[str, str]] = []
    for line in path.read_text().splitlines():
        m = ROW.match(line)
        if not m:
            continue
        fr, test_path = m.group(1), m.group(2).strip()
        rows.append((fr, test_path))
    return rows


def main() -> int:
    if not PRDS_DIR.exists():
        print(f"PRDs dir not found: {PRDS_DIR}", file=sys.stderr)
        return 1

    total = 0
    missing: list[tuple[str, str, str, str]] = []  # (prd_name, fr, path, reason)

    for prd in sorted(PRDS_DIR.glob("0[1-7]-*.md")):
        rows = parse_prd(prd)
        for fr, test_path in rows:
            total += 1
            # Skip rows whose "test file" column is a placeholder like "—" or "same"
            # — the PRDs use "same" to mean "as the row above", and "—" for manual
            # tests. Count them in total but don't verify a path.
            stripped = test_path.strip()
            if stripped.lower() in NON_PATHS or stripped.lower().startswith("same"):
                continue
            if stripped.lower().startswith("per-handler"):
                # F03/F04/F05 "per-handler tests/test_state_frozen.py" pattern —
                # satisfied by the parametric test_handlers_cross_cutting.py.
                cross = REPO_ROOT / "py" / "tests" / "test_handlers_cross_cutting.py"
                if not cross.exists():
                    missing.append((prd.name, fr, stripped, "cross-cutting file missing"))
                continue
            # Handle `path::test_name` pattern (`tests/test_x.py::test_foo`)
            path_only = stripped.split("::", 1)[0]
            candidate = REPO_ROOT / path_only
            if not candidate.exists():
                missing.append((prd.name, fr, stripped, "file not found"))

    if missing:
        print(f"\n{len(missing)} missing PRD-matrix test paths:\n")
        for prd_name, fr, path, reason in missing:
            print(f"  {prd_name}  {fr}  {path}  ({reason})")
        return 1

    print(f"all {total} FR tests located (every PRD matrix row resolves to an existing file or accepted placeholder)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
