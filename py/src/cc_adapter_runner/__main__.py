"""Entry point: ``python -m cc_adapter_runner``."""
from __future__ import annotations

import sys

from _adapter_common.main import build_main

from cc_adapter_runner._allowlist import ALLOWED_ADAPTERS

main = build_main(allowed_adapters=ALLOWED_ADAPTERS, prog="cc_adapter_runner")


if __name__ == "__main__":
    # PR-21β 2026-04-30 — see feishu_adapter_runner.__main__ for rationale.
    import os

    if not os.environ.get("ESR_SPAWN_TOKEN"):
        sys.stderr.write(
            "cc_adapter_runner: must be spawned by esrd via erlexec; "
            "manual `uv run` invocation is unsupported.\n"
            "To debug locally:\n"
            "  esr daemon stop\n"
            "  ESR_SPAWN_TOKEN=__debug__ uv run --project py python -m "
            "cc_adapter_runner ...\n"
        )
        sys.exit(2)

    sys.exit(main(sys.argv[1:]))
