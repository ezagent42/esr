"""ESR v0.1 cc_tmux adapter package.

Public surface is ``esr_cc_tmux.adapter.CcTmuxAdapter`` — launches
Claude Code TUI sessions inside tmux and mediates I/O with them.
See ``esr.toml`` for the installable manifest.
"""

__version__ = "0.1.0"

# Import the adapter module at package-import time so the @adapter
# decorator fires and populates ADAPTER_REGISTRY. Without this,
# `load_adapter_factory("cc_tmux")` imports the package but the class
# never registers → AdapterNotFound.
from . import adapter  # noqa: F401, E402

__all__ = ["adapter"]
