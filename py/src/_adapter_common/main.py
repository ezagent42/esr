"""CLI ``main()`` factory shared by all per-type adapter sidecars.

Each sidecar (``feishu_adapter_runner``, ``cc_adapter_runner``,
``generic_adapter_runner``) calls :func:`build_main` with its own
allowlist and program name. The returned callable parses argv,
validates ``--adapter`` against the allowlist, and delegates to
:func:`_adapter_common.runner_core.run` (wrapped in ``asyncio.run``).

Why a factory (rather than a shared module-level ``main`` that reads
from a dispatch table)? Two reasons:

1. **argparse prog name**: ``--help`` output displays the sidecar's
   own program name so operators see ``feishu_adapter_runner --help``,
   not ``_adapter_common.main --help``.
2. **Allowlist enforcement is per-sidecar policy**: ``feishu`` can
   never enter a ``cc_adapter_runner`` process, so argument validation
   is a trust boundary that the binary itself enforces (belt-and-
   braces alongside :mod:`Esr.WorkerSupervisor`'s dispatch table).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from collections.abc import Callable, Iterable


def build_main(
    *,
    allowed_adapters: Iterable[str] | None,
    prog: str,
) -> Callable[[list[str] | None], int]:
    """Return a ``main(argv)`` callable that enforces ``allowed_adapters``.

    ``allowed_adapters=None`` short-circuits the check — used by
    :mod:`generic_adapter_runner` as a migration fallback. All other
    sidecars pass a non-empty :class:`frozenset` of adapter names.
    """
    allowlist = None if allowed_adapters is None else frozenset(allowed_adapters)

    def _parse(argv: list[str]) -> argparse.Namespace:
        p = argparse.ArgumentParser(
            prog=prog,
            description=f"Run an ESR adapter worker (sidecar: {prog}).",
        )
        p.add_argument("--adapter", required=True, help="Adapter name (e.g. 'feishu').")
        p.add_argument("--instance-id", required=True, help="Instance id in actor namespace.")
        p.add_argument("--url", required=True, help="esrd adapter_hub WebSocket URL.")
        p.add_argument(
            "--config-json", required=True,
            help="JSON blob passed to the adapter factory as config.",
        )
        p.add_argument(
            "--dry-run", action="store_true",
            help="Validate args (including allowlist) and exit without "
                 "opening the WebSocket — used by parametrised dispatch tests.",
        )
        ns = p.parse_args(argv)
        ns.config = json.loads(ns.config_json)
        return ns

    def _check_allowlist(adapter: str) -> int | None:
        """Return None when the adapter is accepted, 2 when rejected.

        Exit code 2 matches argparse's convention for argument errors;
        pytest-based negative assertions can key on the code without
        parsing stderr.
        """
        if allowlist is None:
            return None
        if adapter in allowlist:
            return None
        sys.stderr.write(
            f"{prog}: adapter {adapter!r} not in allowlist "
            f"{sorted(allowlist)!r}; refusing to start.\n"
        )
        return 2

    def main(argv: list[str] | None = None) -> int:
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(levelname)s %(name)s %(message)s",
        )
        ns = _parse(argv if argv is not None else [])

        rejection = _check_allowlist(ns.adapter)
        if rejection is not None:
            return rejection

        if ns.dry_run:
            # argv-only validation path — every per-sidecar allowlist
            # test uses this flag so pytest can run without a running
            # esrd on the loopback interface.
            return 0

        # Import lazily so ``--help`` and allowlist rejection don't
        # pull in the full adapter-loader import tree.
        from _adapter_common.runner_core import run

        try:
            asyncio.run(run(ns.adapter, ns.instance_id, ns.config, ns.url))
        except KeyboardInterrupt:
            return 0
        except BaseException as exc:  # noqa: BLE001 — ExceptionGroup is BaseException
            import traceback
            print(f"{prog} FAIL: {exc}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            return 1
        return 0

    return main
