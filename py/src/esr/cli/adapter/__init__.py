"""``esr.cli.adapter`` package — adapter-type-scoped CLI subgroups.

The top-level ``adapter`` click group (``add`` / ``install`` / ``list``)
lives in ``esr.cli.main`` alongside the other CLI groups; this package
hosts per-adapter-type subgroups that are too fat to inline there. The
first entry is ``feishu`` (DI-8 Task 15) — the L3 paste-based
``create-app`` wizard.

Note: we intentionally do NOT ``from .feishu import feishu`` at the
package level because that re-binding shadows the submodule on
``esr.cli.adapter`` (Python attribute-lookup order: package attrs win
over submodule resolution once the name is bound). Callers import from
the submodule path directly: ``from esr.cli.adapter.feishu import
feishu``.
"""
from __future__ import annotations

# Ensure the submodule is loaded so ``esr.cli.adapter.feishu`` resolves
# when the package is imported in isolation.
from esr.cli.adapter import feishu as _feishu  # noqa: F401
