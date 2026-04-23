"""Feishu-only adapter sidecar (PR-4b P4b-2).

Per-type sidecar that hosts Feishu adapter instances. Speaks Phoenix
channels to esrd's ``adapter_hub`` — not stdin/stdout — so it does not
use :class:`Esr.PyProcess`; :mod:`Esr.WorkerSupervisor` launches it via
``python -m feishu_adapter_runner --adapter feishu --instance-id ... --url ...``.

The dispatch table in :mod:`Esr.WorkerSupervisor` routes adapter name
``"feishu"`` to this module; ``_allowlist.ALLOWED_ADAPTERS`` mirrors the
table on the Python side so an accidental wrong-adapter argv (e.g. a
stale script hard-coded to ``cc_tmux``) fails fast rather than booting
the wrong adapter in the wrong sidecar.
"""
