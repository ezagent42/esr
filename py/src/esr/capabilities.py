"""SDK-shared capability check mirroring Esr.Capabilities semantics.

Loaded from the same ``capabilities.yaml`` as the runtime. Whole-segment
``*`` wildcards only — no prefix globs. Must agree byte-for-byte with
``runtime/lib/esr/capabilities/grants.ex`` so Lane A (adapter) and Lane B
(runtime) decisions cannot diverge.

Wildcard semantics (spec §3.3, mirrored from ``Grants.matches?/2`` in
Elixir):

- bare ``*`` as the held capability grants everything
- held capability must parse as ``<prefix>:<name>/<perm>`` — the prefix
  (e.g. ``workspace``) MUST match literally; only ``name`` and ``perm``
  honour whole-segment ``*``
- prefix globs (``session.*``, ``msg.*``) do not match — only a bare
  ``*`` substituted for an entire segment

Every Python adapter that needs Lane A enforcement uses this class; the
adapter passes the path to ``__init__``. Reload is cheap and
mtime-gated (see ``reload()``), so calling it on every check is safe.
"""
from __future__ import annotations

from pathlib import Path

import yaml


class CapabilitiesChecker:
    """File-backed capability checker with lazy mtime-gated reload.

    The snapshot is ``{principal_id: [held_capability, ...]}``. Missing
    file resolves to an empty snapshot (default-deny); the caller
    (adapter) enforces "no one is allowed yet" until admin runs
    ``esr cap grant`` or boot-time ``ESR_BOOTSTRAP_PRINCIPAL_ID``
    creates the file.
    """

    def __init__(self, path: Path) -> None:
        self._path = Path(path)
        self._snapshot: dict[str, list[str]] = {}
        self._mtime: float | None = None
        self.reload()

    def reload(self) -> None:
        """Reread the YAML file if its mtime has changed since the
        last load.

        Keeps the hot path cheap — callers can invoke ``reload()`` on
        every check without rereading the file each time. Picks up
        admin edits within one inbound message.
        """
        try:
            stat = self._path.stat()
        except FileNotFoundError:
            if self._mtime is not None or self._snapshot:
                self._snapshot = {}
                self._mtime = None
            return

        mtime = stat.st_mtime
        if self._mtime is not None and mtime == self._mtime:
            return

        try:
            doc = yaml.safe_load(self._path.read_text()) or {}
        except yaml.YAMLError:
            # Malformed yaml → keep the previous snapshot, bump mtime
            # so we don't reread repeatedly. An admin editing the file
            # into a broken state is better handled as "stale valid
            # snapshot" than "suddenly deny everything".
            self._mtime = mtime
            return

        principals = doc.get("principals") or []
        self._snapshot = {
            entry["id"]: list(entry.get("capabilities", []))
            for entry in principals
            if isinstance(entry, dict) and "id" in entry
        }
        self._mtime = mtime

    def has(self, principal_id: str, permission: str) -> bool:
        """True if ``principal_id`` holds a capability matching ``permission``.

        Rereads the yaml file if its mtime changed. ``principal_id``
        absent from the file → False.
        """
        self.reload()
        held = self._snapshot.get(principal_id, [])
        return any(self._matches(h, permission) for h in held)

    @staticmethod
    def _matches(held: str, required: str) -> bool:
        """Port of ``Grants.matches?/2`` (runtime/lib/esr/capabilities/grants.ex).

        Splits both held and required into ``(prefix, name, perm)``;
        the prefix (e.g. ``workspace``) must match literally, while
        ``name`` and ``perm`` each match literally OR if the held
        segment is bare ``*``.
        """
        if held == "*":
            return True
        h = CapabilitiesChecker._split(held)
        r = CapabilitiesChecker._split(required)
        if h is None or r is None:
            return False
        h_prefix, h_name, h_perm = h
        r_prefix, r_name, r_perm = r
        if h_prefix != r_prefix:
            return False
        return (
            CapabilitiesChecker._segment_match(h_name, r_name)
            and CapabilitiesChecker._segment_match(h_perm, r_perm)
        )

    @staticmethod
    def _split(s: str) -> tuple[str, str, str] | None:
        """Parse ``<prefix>:<name>/<perm>`` → ``(prefix, name, perm)``.

        Returns None if the string has neither shape (e.g. missing
        ``/``, missing ``:`` in the scope half).
        """
        if "/" not in s:
            return None
        scope, perm = s.split("/", 1)
        if ":" not in scope:
            return None
        prefix, name = scope.split(":", 1)
        return prefix, name, perm

    @staticmethod
    def _segment_match(held: str, required: str) -> bool:
        """Whole-segment match: bare ``*`` wildcards any segment, else literal."""
        if held == "*":
            return True
        return held == required
