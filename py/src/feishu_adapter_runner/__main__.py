"""Entry point: ``python -m feishu_adapter_runner``.

Delegates to :func:`_adapter_common.main.build_main` with this sidecar's
allowlist and program name. Every dispatch / runtime detail lives in
``_adapter_common`` so this glue is ~5 lines.
"""
from __future__ import annotations

import sys

from _adapter_common.main import build_main

from feishu_adapter_runner._allowlist import ALLOWED_ADAPTERS

main = build_main(allowed_adapters=ALLOWED_ADAPTERS, prog="feishu_adapter_runner")


if __name__ == "__main__":
    # PR-21β 2026-04-30 — fail fast if not spawned by esrd. Without this
    # guard, `uv run -m feishu_adapter_runner` would create an orphan
    # adapter competing for Feishu app credentials with the esrd-managed
    # one (today's 8x-orphan incident motivated this). Token is generated
    # fresh per BEAM boot in Esr.Application.start/2.
    import os

    if not os.environ.get("ESR_SPAWN_TOKEN"):
        sys.stderr.write(
            "feishu_adapter_runner: must be spawned by esrd via erlexec; "
            "manual `uv run` invocation is unsupported (would create orphan "
            "adapter competing for Feishu app credentials).\n"
            "To debug locally:\n"
            "  esr daemon stop\n"
            "  ESR_SPAWN_TOKEN=__debug__ uv run --project py python -m "
            "feishu_adapter_runner ...\n"
        )
        sys.exit(2)

    sys.exit(main(sys.argv[1:]))
