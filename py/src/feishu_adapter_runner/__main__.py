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
    sys.exit(main(sys.argv[1:]))
