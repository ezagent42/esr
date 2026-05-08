"""esr:// URI parser + builder (PRD 02 F15, spec §7.5 + 2026-04-27 actor-topology-routing extension).

Canonical forms::

    esr://[org@]host[:port]/<type>/<id>[?k=v&...]                     # legacy 2-segment
    esr://[org@]host[:port]/<type>(/<seg>)+[?k=v&...]                 # path-style RESTful

Legacy 2-segment types (still emitted today): ``adapter``, ``actor``,
``command``. Path-style RESTful types (introduced 2026-04-27):
``adapters``, ``workspaces``, ``chats``, ``users``, ``sessions`` —
followed by 1+ more path segments forming a hierarchical resource
address.

Empty host is a hard error (paths like ``esr:///foo/bar`` are
ill-formed — the host is the anchor for cross-boundary routing).

The parser is intentionally strict: anything the spec doesn't allow
is rejected with ``ValueError``. This is the Python counterpart of
``Esr.Uri`` in the Elixir runtime (PRD 01 F17) — the two must agree
on wire-level URI strings for IPC.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Any, TypedDict
from urllib.parse import parse_qsl

# Legacy types: 2-segment URIs (single id, no slashes inside).
_LEGACY_TYPES = frozenset({"adapter", "actor", "command"})

# Path-style RESTful types: 2+ segment URIs (hierarchical resource path).
_PATH_STYLE_TYPES = frozenset({"adapters", "workspaces", "chats", "users", "sessions", "resources"})

_VALID_TYPES = _LEGACY_TYPES | _PATH_STYLE_TYPES


def legacy_types() -> frozenset[str]:
    """Return the legacy type set (single-id, 2-segment URIs)."""
    return _LEGACY_TYPES


def path_style_types() -> frozenset[str]:
    """Return the path-style RESTful type set (introduced 2026-04-27)."""
    return _PATH_STYLE_TYPES


@dataclass(frozen=True)
class EsrURI:
    """Parsed ``esr://`` URI.

    For legacy 2-segment URIs, ``type``/``id`` carry the parsed pair and
    ``segments`` is ``[type, id]``. For path-style URIs, ``type`` is the
    first segment, ``id`` is the last segment, and ``segments`` is the
    full path (3+ entries).
    """

    org: str | None
    host: str
    port: int | None
    type: str
    id: str
    segments: tuple[str, ...] = field(default=())
    params: MappingProxyType[str, str] = field(
        default_factory=lambda: MappingProxyType({})
    )

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, EsrURI):
            return NotImplemented
        return (
            self.org == other.org
            and self.host == other.host
            and self.port == other.port
            and self.type == other.type
            and self.id == other.id
            and tuple(self.segments) == tuple(other.segments)
            and dict(self.params) == dict(other.params)
        )

    def __hash__(self) -> int:
        return hash(
            (
                self.org,
                self.host,
                self.port,
                self.type,
                self.id,
                tuple(self.segments),
                tuple(sorted(self.params.items())),
            )
        )


def parse(s: str) -> EsrURI:
    """Parse an ``esr://`` URI string into an ``EsrURI``."""
    if not s.startswith("esr://"):
        raise ValueError(f"expected esr:// scheme; got {s!r}")
    rest = s[len("esr://") :]

    # Split authority / path ? query
    path_and_query = rest
    query = ""
    if "?" in path_and_query:
        path_and_query, query = path_and_query.split("?", 1)

    authority, _, raw_path = path_and_query.partition("/")
    if raw_path == "" and "/" not in path_and_query:
        raise ValueError(f"missing path in {s!r}")

    # authority = [org@]host[:port]
    org: str | None = None
    if "@" in authority:
        org, _, authority = authority.partition("@")
        if org == "":
            raise ValueError(f"empty org in {s!r}")

    host_str, _, port_str = authority.partition(":")
    if host_str == "":
        raise ValueError(f"empty host in {s!r}")

    port: int | None = None
    if port_str:
        try:
            port = int(port_str)
        except ValueError as exc:
            raise ValueError(f"invalid port {port_str!r} in {s!r}") from exc

    # Path: legacy 2-segment OR path-style 2+ segment.
    raw_segments = raw_path.split("/")
    # Preserve trailing-empty info for "missing id" detection (`adapter/`).
    has_trailing_empty = raw_segments[-1] == "" and len(raw_segments) > 1
    path_parts = [p for p in raw_segments if p != ""]
    if len(path_parts) < 2 and not has_trailing_empty:
        raise ValueError(f"bad path in {s!r}: at least <type>/<id> required")

    if len(path_parts) == 0:
        raise ValueError(f"bad path in {s!r}: at least <type>/<id> required")

    type_ = path_parts[0]
    if type_ not in _VALID_TYPES:
        raise ValueError(
            f"unknown type {type_!r}; expected one of {sorted(_VALID_TYPES)}"
        )

    if type_ in _LEGACY_TYPES:
        # Legacy types stay strict: exactly 2 segments, id is the second.
        if len(path_parts) == 1 and has_trailing_empty:
            raise ValueError(f"missing id in {s!r}")
        if len(path_parts) != 2:
            raise ValueError(
                f"bad path in {s!r}: legacy type {type_!r} requires exactly "
                f"<type>/<id> (no slashes in id)"
            )
        id_ = path_parts[1]
    else:
        # Path-style types accept 2+ segments. id is the last segment.
        if len(path_parts) < 2:
            raise ValueError(f"missing id in {s!r}")
        id_ = path_parts[-1]

    if id_ == "":
        raise ValueError(f"missing id in {s!r}")

    params_dict: dict[str, str] = dict(parse_qsl(query, keep_blank_values=True))

    return EsrURI(
        org=org,
        host=host_str,
        port=port,
        type=type_,
        id=id_,
        segments=tuple(path_parts),
        params=MappingProxyType(params_dict),
    )


def build(
    type_: str,
    id_: str,
    *,
    host: str,
    port: int | None = None,
    org: str | None = None,
    params: dict[str, Any] | None = None,
) -> str:
    """Build a canonical 2-segment ``esr://`` URI string (legacy form)."""
    if type_ not in _VALID_TYPES:
        raise ValueError(f"unknown type {type_!r}")
    if host == "":
        raise ValueError("empty host")
    if id_ == "":
        raise ValueError("empty id")

    authority = host
    if port is not None:
        authority = f"{authority}:{port}"
    if org:
        authority = f"{org}@{authority}"

    s = f"esr://{authority}/{type_}/{id_}"

    if params:
        from urllib.parse import urlencode

        s = f"{s}?{urlencode(params)}"
    return s


def build_path(
    segments: list[str] | tuple[str, ...],
    *,
    host: str,
    port: int | None = None,
    org: str | None = None,
    env: str | None = None,
    params: dict[str, Any] | None = None,
) -> str:
    """Build a path-style ``esr://`` URI from path segments.

    The first segment must be a path-style type
    (e.g. ``adapters``, ``workspaces``, ``chats``, ``users``, ``sessions``,
    ``resources``). Use ``build`` for legacy 2-segment forms.

    ``env=`` is an alias for ``org=`` (aligned with Elixir ``Esr.Uri.build_path/3``).
    """
    if len(segments) < 2:
        raise ValueError(
            f"path-style URI requires at least 2 segments; got {list(segments)!r}"
        )
    first = segments[0]
    if first not in _PATH_STYLE_TYPES:
        raise ValueError(
            f"first segment {first!r} is not a path-style type "
            f"(expected one of {sorted(_PATH_STYLE_TYPES)})"
        )
    if host == "":
        raise ValueError("empty host")
    for i, seg in enumerate(segments):
        if seg == "":
            raise ValueError(f"empty segment at index {i} in {list(segments)!r}")

    org_arg = env or org
    authority = host
    if port is not None:
        authority = f"{authority}:{port}"
    if org_arg:
        authority = f"{org_arg}@{authority}"

    s = f"esr://{authority}/" + "/".join(segments)

    if params:
        from urllib.parse import urlencode

        s = f"{s}?{urlencode(params)}"
    return s


# ---------------------------------------------------------------------------
# Resources URI helpers (introduced 2026-05-08, multimedia content protocol)
# Mirror of Esr.Uri.parse_resource/1 and Esr.Uri.build_resource/3 (commit 018c21a).
# ---------------------------------------------------------------------------


class ParsedResource(TypedDict):
    """Precise return type for :func:`parse_resource`.

    ``media_type``, ``sha256``, ``ext``, and ``host`` are always populated
    (validated against allowlists before returning). ``env`` is ``str | None``
    because the ``org@`` authority component is optional in resource URIs.
    """

    media_type: str
    sha256: str
    ext: str
    env: str | None
    host: str

_ALLOWED_EXTS: dict[str, tuple[str, ...]] = {
    "image": ("png", "jpg", "jpeg", "gif", "webp", "heic"),
    "file":  ("bin", "pdf", "doc", "docx", "xls", "xlsx", "zip", "txt", "md", "csv"),
    "audio": ("opus", "mp3", "wav", "m4a", "aac"),
}

_MEDIA_TYPES: tuple[str, ...] = tuple(_ALLOWED_EXTS)  # single source of truth

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def parse_resource(uri: str) -> ParsedResource:
    """Parse a resources URI and return a dict with media_type, sha256, ext, env, host.

    Raises ``ValueError('invalid_uri: ...')`` on:
    - non-resources URI type
    - wrong segment count (must be 3: ['resources', media_type, '<sha>.<ext>'])
    - unknown media_type (not in image/file/audio)
    - sha256 not exactly 64 lowercase hex
    - ext not in per-media-type allowlist

    Mirror of ``Esr.Uri.parse_resource/1`` (Elixir, commit 018c21a).
    Ext is normalized to lowercase per spec D7.
    """
    parsed = parse(uri)
    if parsed.type != "resources":
        raise ValueError("invalid_uri: not a resources URI")
    if len(parsed.segments) != 3:
        raise ValueError("invalid_uri: bad segment count")

    _, mt_str, last_seg = parsed.segments
    if mt_str not in _MEDIA_TYPES:
        raise ValueError(f"invalid_uri: unknown media_type {mt_str!r}")

    if "." not in last_seg:
        raise ValueError("invalid_uri: missing ext")
    sha, ext = last_seg.rsplit(".", 1)
    ext = ext.lower()  # normalize per spec D7

    if not _SHA256_RE.match(sha):
        raise ValueError("invalid_uri: sha256 must be 64 lowercase hex chars")
    if ext not in _ALLOWED_EXTS[mt_str]:
        raise ValueError(f"invalid_uri: ext {ext!r} not in allowlist for {mt_str!r}")

    return {
        "media_type": mt_str,
        "sha256": sha,
        "ext": ext,
        "env": parsed.org,
        "host": parsed.host,
    }


def build_resource(
    media_type: str,
    sha256: str,
    *,
    ext: str = "bin",
    env: str | None = None,
    host: str = "localhost",
) -> str:
    """Construct a resources URI. Raises ``ValueError`` on invalid input.

    Mirror of ``Esr.Uri.build_resource/3`` (Elixir, commit 018c21a).
    """
    ext = str(ext).lower()
    if not _SHA256_RE.match(sha256):
        raise ValueError(
            f"build_resource: sha256 must be 64 lowercase hex chars, got: {sha256!r}"
        )
    if media_type not in _ALLOWED_EXTS:
        raise ValueError(f"build_resource: unknown media_type {media_type!r}")
    if ext not in _ALLOWED_EXTS[media_type]:
        raise ValueError(
            f"build_resource: ext {ext!r} not in allowlist for media_type {media_type!r}"
        )

    return build_path(
        ["resources", media_type, f"{sha256}.{ext}"],
        host=host,
        env=env,
    )
