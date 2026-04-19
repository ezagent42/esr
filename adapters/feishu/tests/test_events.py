"""PRD 04 F13 — feishu per-msg_type parsers."""

from __future__ import annotations

from esr_feishu.parsers import parse_content


# --- P0 ----------------------------------------------------------------


def test_parse_text() -> None:
    assert parse_content("text", {"text": "hello"}) == "hello"


def test_parse_text_missing_field() -> None:
    assert parse_content("text", {}) == ""


def test_parse_post() -> None:
    content = {
        "title": "daily standup",
        "content": [
            [
                {"tag": "text", "text": "hi team"},
                {"tag": "at", "user_id": "ou_1", "user_name": "Alice"},
            ],
            [{"tag": "img", "image_key": "img_xyz"}],
        ],
    }
    out = parse_content("post", content)
    assert "daily standup" in out
    assert "hi team" in out
    assert "@Alice" in out
    assert "img_xyz" in out


def test_parse_image_returns_stub_with_file_key() -> None:
    content = {"image_key": "img_abc", "file_name": "photo.png"}
    out = parse_content("image", content)
    assert "photo.png" in out


def test_parse_file_prefers_file_key() -> None:
    content = {"file_key": "f_1", "file_name": "doc.pdf"}
    assert parse_content("file", content) == "[file: doc.pdf]"


def test_parse_sticker() -> None:
    assert parse_content("sticker", {}) == "[sticker]"


# --- P1 ----------------------------------------------------------------


def test_parse_share_chat() -> None:
    assert parse_content("share_chat", {"chat_id": "oc_x"}) == "[chat card: oc_x]"


def test_parse_share_user() -> None:
    assert parse_content("share_user", {"user_id": "ou_x"}) == "[user card: ou_x]"


def test_parse_location_with_coords() -> None:
    out = parse_content(
        "location", {"name": "Beijing", "latitude": 39.9, "longitude": 116.4}
    )
    assert "Beijing" in out
    assert "39.9" in out
    assert "116.4" in out


def test_parse_location_without_coords() -> None:
    out = parse_content("location", {"name": "somewhere"})
    assert out == "[location: somewhere]"


def test_parse_interactive_card_with_header_and_elements() -> None:
    content = {
        "header": {"title": {"content": "Card title"}},
        "elements": [
            {"tag": "markdown", "content": "**bold** text"},
            {"tag": "action", "actions": [{"text": {"content": "Approve"}}]},
        ],
    }
    out = parse_content("interactive", content)
    assert "Card title" in out
    assert "bold" in out
    assert "[button: Approve]" in out


# --- fallbacks ---------------------------------------------------------


def test_unknown_msg_type_falls_back() -> None:
    out = parse_content("bogus_type", {})
    assert out == "[bogus_type message]"


def test_parser_exception_is_caught() -> None:
    """A malformed payload that breaks a parser returns a safe placeholder."""
    # content['content'] = 5 is non-iterable, so `for para in 5` raises TypeError
    out = parse_content("post", {"content": 5})
    assert out == "[post message — parse failed]"