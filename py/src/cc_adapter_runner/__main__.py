"""Entry point: ``python -m cc_adapter_runner``."""
from __future__ import annotations

import sys

from _adapter_common.main import build_main

from cc_adapter_runner._allowlist import ALLOWED_ADAPTERS

main = build_main(allowed_adapters=ALLOWED_ADAPTERS, prog="cc_adapter_runner")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
