"""
Content-addressed media storage + URI <-> Path resolver. Mirror of
runtime/lib/esr/resource/media.ex per spec
docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md §3.2.

Used by the Feishu Python sidecar's _download_file directive (Phase 2)
to content-address bytes fetched from Lark and return a stable
esr:// URI to the Elixir caller.

Errors are raised as EsrResourceError with reason in message ("invalid_uri",
"wrong_env", "not_found", "unsupported_ext", "source_not_found").
"""
import hashlib
import json
import os
import pathlib
from datetime import datetime, timezone

from esr.uri import parse_resource, build_resource


class EsrResourceError(Exception):
    """Raised by resolve/store on any failure. Message starts with the
    reason atom-equivalent string (invalid_uri / wrong_env / not_found /
    unsupported_ext / source_not_found)."""


_ALLOWED_EXTS = {
    "image": ("png", "jpg", "jpeg", "gif", "webp", "heic"),
    "file":  ("bin", "pdf", "doc", "docx", "xls", "xlsx", "zip", "txt", "md", "csv"),
    "audio": ("opus", "mp3", "wav", "m4a", "aac"),
}


def _esrd_home() -> pathlib.Path:
    return pathlib.Path(os.environ.get("ESRD_HOME", os.path.expanduser("~/.esrd")))


def _env() -> str:
    return os.environ.get("ESR_INSTANCE", "default")


def _host_port() -> str:
    """MVP: matches Esr.Resource.Media.LocalAddress fallback. ESRD_HOST_PORT
    env var override is a future-work hook (cross-host)."""
    return os.environ.get("ESRD_HOST_PORT", "localhost:4001")


def _resource_dir(media_type: str) -> pathlib.Path:
    return _esrd_home() / _env() / "resources" / media_type


def _validate_media_type_and_ext(media_type: str, ext: str) -> None:
    """Mirrors Elixir's validate_media_type_and_ext/2.
    Raises EsrResourceError('unsupported_ext: ...') if (media_type, ext)
    is not a known combo."""
    if media_type not in _ALLOWED_EXTS:
        raise EsrResourceError(f"unsupported_ext: unknown media_type {media_type!r}")
    if ext not in _ALLOWED_EXTS[media_type]:
        raise EsrResourceError(
            f"unsupported_ext: ext {ext!r} not in allowlist for media_type {media_type!r}"
        )


def resolve(uri: str) -> pathlib.Path:
    """URI -> local Path. Raises EsrResourceError on:
    - invalid_uri (parse error or wrong type)
    - wrong_env (URI's env != local env)
    - not_found (file does not exist)
    """
    try:
        parsed = parse_resource(uri)
    except ValueError as e:
        raise EsrResourceError(f"invalid_uri: {e}") from e

    env_in = parsed.get("env")
    if env_in is not None and env_in != _env():
        raise EsrResourceError(f"wrong_env: uri claims {env_in!r} but local is {_env()!r}")

    p = _resource_dir(parsed["media_type"]) / f"{parsed['sha256']}.{parsed['ext']}"
    if not p.exists():
        raise EsrResourceError(f"not_found: {p}")
    return p


def store(media_type: str, source_path: str, ref_meta: dict) -> dict:
    """Content-address source_path under resources/<media_type>/<sha>.<ext>;
    append a JSON ref line to <sha>.refs.jsonl.

    Pre-validates (media_type, ext) before any I/O -- raises
    EsrResourceError('unsupported_ext: ...') if the combo is invalid.

    Returns {uri, sha256, path}. Concurrent calls with same SHA are safe:
    same dest, refs append independently.
    """
    src = pathlib.Path(source_path)
    if not src.exists():
        raise EsrResourceError(f"source_not_found: {src}")

    ext = src.suffix.lstrip(".").lower() or "bin"
    _validate_media_type_and_ext(media_type, ext)

    h = hashlib.sha256()
    with src.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    sha = h.hexdigest()

    target_dir = _resource_dir(media_type)
    target_dir.mkdir(parents=True, exist_ok=True)
    dest = target_dir / f"{sha}.{ext}"

    if not dest.exists():
        # atomic copy: tmp + rename (POSIX atomic on same FS)
        tmp = target_dir / f"{sha}.{ext}.tmp.{os.getpid()}.{id(src)}"
        with src.open("rb") as r, tmp.open("wb") as w:
            while chunk := r.read(65536):
                w.write(chunk)
        tmp.replace(dest)

    # append ref (POSIX-atomic append for <=PIPE_BUF lines)
    ref = dict(ref_meta)
    ref["received_at"] = datetime.now(timezone.utc).isoformat()
    refs_path = target_dir / f"{sha}.refs.jsonl"
    with refs_path.open("a") as f:
        f.write(json.dumps(ref, separators=(",", ":")) + "\n")

    uri = build_resource(media_type, sha, ext=ext, env=_env(), host=_host_port())
    return {"uri": uri, "sha256": sha, "path": str(dest)}
