"""Mirror of runtime/test/esr/resource/media/media_test.exs +
phaser_registry_test.exs. Verifies parity between Python and Elixir
resource.media implementations."""

import hashlib
from pathlib import Path

import pytest

from esr.resource.media import EsrResourceError, resolve, store
from esr.resource.media.phaser_registry import transform


@pytest.fixture
def tmp_esrd(tmp_path, monkeypatch):
    monkeypatch.setenv("ESRD_HOME", str(tmp_path))
    monkeypatch.setenv("ESR_INSTANCE", "test")
    return tmp_path


def test_store_writes_content_addressed_and_appends_refs(tmp_esrd):
    src = tmp_esrd / "input.png"
    src.write_bytes(b"fake png bytes")
    expected_sha = hashlib.sha256(b"fake png bytes").hexdigest()

    result = store("image", str(src), {"adapter": "test", "chat_id": "oc_xx"})

    assert result["sha256"] == expected_sha
    stored = Path(result["path"])
    assert stored.exists()
    assert f"/test/resources/image/{expected_sha}.png" in str(stored)
    assert "esr://test@" in result["uri"]
    assert f"/resources/image/{expected_sha}.png" in result["uri"]

    refs = stored.parent / f"{expected_sha}.refs.jsonl"
    assert refs.exists()
    lines = refs.read_text().strip().split("\n")
    assert len(lines) == 1


def test_store_dedups_same_bytes(tmp_esrd):
    a = tmp_esrd / "a.png"
    b = tmp_esrd / "b.png"
    a.write_bytes(b"same")
    b.write_bytes(b"same")
    r1 = store("image", str(a), {"chat": "1"})
    r2 = store("image", str(b), {"chat": "2"})
    assert r1["sha256"] == r2["sha256"]
    assert r1["path"] == r2["path"]
    refs = Path(r2["path"]).parent / f"{r2['sha256']}.refs.jsonl"
    assert len(refs.read_text().strip().split("\n")) == 2


def test_store_bin_extension_for_no_ext_source(tmp_esrd):
    src = tmp_esrd / "no_ext"
    src.write_bytes(b"blob")
    result = store("file", str(src), {})
    assert result["path"].endswith(".bin")


def test_store_returns_unsupported_ext_for_wrong_combo(tmp_esrd):
    """Mirror Elixir's :unsupported_ext behavior -- raises EsrResourceError."""
    src = tmp_esrd / "wrong.mp3"
    src.write_bytes(b"fake mp3")
    with pytest.raises(EsrResourceError, match="unsupported_ext"):
        store("image", str(src), {})

    # Verify no file written to resources dir
    image_dir = tmp_esrd / "test" / "resources" / "image"
    if image_dir.exists():
        assert not any(image_dir.iterdir())


def test_resolve_round_trip(tmp_esrd):
    src = tmp_esrd / "x.png"
    src.write_bytes(b"data")
    result = store("image", str(src), {})
    p = resolve(result["uri"])
    assert str(p) == result["path"]


@pytest.mark.usefixtures("tmp_esrd")
def test_resolve_not_found_raises():
    bogus = "esr://test@localhost:4001/resources/image/" + ("0" * 64) + ".png"
    with pytest.raises(EsrResourceError, match="not_found"):
        resolve(bogus)


@pytest.mark.usefixtures("tmp_esrd")
def test_resolve_wrong_env_raises():
    bad = "esr://other@localhost:4001/resources/image/" + ("a" * 64) + ".png"
    with pytest.raises(EsrResourceError, match="wrong_env"):
        resolve(bad)


@pytest.mark.usefixtures("tmp_esrd")
def test_resolve_invalid_uri_raises():
    with pytest.raises(EsrResourceError, match="invalid_uri"):
        resolve("not-a-uri")


def test_resolve_absent_env_implicit_local(tmp_esrd):
    src = tmp_esrd / "y.png"
    src.write_bytes(b"y")
    result = store("image", str(src), {})
    sha = result["sha256"]
    # URI without env@ segment; should resolve as local env
    no_env_uri = f"esr://localhost:4001/resources/image/{sha}.png"
    p = resolve(no_env_uri)
    assert str(p) == result["path"]


def test_phaser_registry_path(tmp_esrd):
    src = tmp_esrd / "x.png"
    src.write_bytes(b"\x89PNG\r\n\x1a\nfake")
    result = store("image", str(src), {})
    out = transform(result["uri"], "path")
    assert str(out).endswith(".png")


def test_phaser_registry_bytes(tmp_esrd):
    src = tmp_esrd / "y.png"
    src.write_bytes(b"hello")
    result = store("image", str(src), {})
    out = transform(result["uri"], "bytes")
    assert out == b"hello"


def test_phaser_registry_base64_data_url(tmp_esrd):
    src = tmp_esrd / "y.png"
    src.write_bytes(b"\x89PNG\r\n\x1a\nfake")
    result = store("image", str(src), {})
    out = transform(result["uri"], "base64_data_url")
    assert out.startswith("data:image/png;base64,")


def test_phaser_registry_file_inline_text(tmp_esrd):
    src = tmp_esrd / "small.txt"
    src.write_bytes(b"hello world")
    result = store("file", str(src), {})
    out = transform(result["uri"], "inline_text")
    assert out == "hello world"


def test_phaser_registry_no_phaser_for_audio(tmp_esrd):
    """Audio has no Phaser in MVP; transform should raise."""
    sha = "c" * 64
    audio_dir = tmp_esrd / "test" / "resources" / "audio"
    audio_dir.mkdir(parents=True)
    (audio_dir / f"{sha}.opus").write_bytes(b"audio")
    audio_uri = f"esr://test@localhost:4001/resources/audio/{sha}.opus"
    with pytest.raises(ValueError, match="no_phaser_for_media_type"):
        transform(audio_uri, "path")
