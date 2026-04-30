"""Entry point: ``python -m generic_adapter_runner``.

Unlike :mod:`feishu_adapter_runner` / :mod:`cc_adapter_runner`, this
sidecar uses ``allowed_adapters=None`` in :func:`_adapter_common.main.build_main`
— the allowlist gate is short-circuited so unknown adapter names fall
through. A :class:`DeprecationWarning` is printed on stderr at startup
so operators see that the process is running on the migration fallback.
"""
from __future__ import annotations

import sys
import warnings

from _adapter_common.main import build_main


def _emit_deprecation_warning() -> None:
    """Print a single stderr warning when the sidecar boots.

    Uses :mod:`warnings` (rather than a bare ``print``) so downstream
    tooling — e.g. pytest's ``filterwarnings`` markers — can suppress
    the message in tests that intentionally exercise the fallback
    path. The ``stacklevel=2`` points at the caller (argparse line in
    :func:`_adapter_common.main.build_main`'s returned main, practically
    the user's command-line invocation).
    """
    warnings.warn(
        "generic_adapter_runner is a migration fallback; add --adapter "
        "<name> to a dedicated sidecar's allowlist (or create a new "
        "sidecar) and update Esr.WorkerSupervisor's dispatch table.",
        DeprecationWarning,
        stacklevel=2,
    )


main = build_main(allowed_adapters=None, prog="generic_adapter_runner")


def _entry() -> int:
    _emit_deprecation_warning()
    return main(sys.argv[1:])


if __name__ == "__main__":
    # PR-21β 2026-04-30 — see feishu_adapter_runner.__main__ for rationale.
    import os

    if not os.environ.get("ESR_SPAWN_TOKEN"):
        sys.stderr.write(
            "generic_adapter_runner: must be spawned by esrd via erlexec; "
            "manual `uv run` invocation is unsupported.\n"
            "To debug locally:\n"
            "  esr daemon stop\n"
            "  ESR_SPAWN_TOKEN=__debug__ uv run --project py python -m "
            "generic_adapter_runner ...\n"
        )
        sys.exit(2)

    sys.exit(_entry())
