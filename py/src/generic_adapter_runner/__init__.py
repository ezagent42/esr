"""Generic adapter sidecar catch-all (PR-4b P4b-4).

The dispatch table in :mod:`Esr.WorkerSupervisor` routes *known* adapter
names to dedicated sidecars (``feishu`` → ``feishu_adapter_runner``,
``cc_tmux``/``cc_mcp`` → ``cc_adapter_runner``) and falls through to
**this** sidecar for anything else. It exists purely as a migration
fallback: any new adapter added to the codebase works immediately, with
a :class:`DeprecationWarning` on stderr prompting the author to add a
proper allowlist entry to one of the dedicated sidecars (or create a
new one) before cutover.

Long-term (PR-5 or later) this module is expected to be deleted once
every adapter has a typed home; the deprecation warning tracks that
work.
"""
