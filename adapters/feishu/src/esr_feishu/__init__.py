"""ESR v0.1 Feishu adapter package.

Public surface is ``esr_feishu.adapter.FeishuAdapter`` — registered
with the ESR runtime via the ``@adapter`` decorator at import time.
See ``esr.toml`` for the installable manifest.
"""

__version__ = "0.1.0"

# Import the adapter module at package-import time so @adapter fires.
from . import adapter  # noqa: F401, E402

__all__ = ["adapter"]
