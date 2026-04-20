"""PRD 05 F07 / F08 / F09 — feishu_app.on_msg."""

from __future__ import annotations

from esr import Event, InvokeCommand, Route


def _msg(content: str, *, thread_id: str | None = None) -> Event:
    args: dict = {"content": content}
    if thread_id is not None:
        args["thread_id"] = thread_id
    return Event(source="esr://localhost/adapter/feishu", event_type="msg_received", args=args)


# --- F07: /new-thread ---------------------------------------------------


def test_new_thread_triggers_invoke_command() -> None:
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    new_s, actions = on_msg(s, _msg("/new-thread foo"))
    assert new_s.bound_threads == frozenset({"foo"})
    assert len(actions) == 1
    assert isinstance(actions[0], InvokeCommand)
    assert actions[0].name == "feishu-thread-session"
    # 8f: chat_id forwarded from event.args so the spawned feishu_thread
    # can reply to the originating Feishu chat immediately.
    assert actions[0].params == {"thread_id": "foo", "chat_id": ""}


def test_new_thread_duplicate_is_idempotent() -> None:
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState(bound_threads=frozenset({"foo"}))
    new_s, actions = on_msg(s, _msg("/new-thread foo"))
    assert new_s is s  # same instance — no change
    assert actions == []


def test_new_thread_malformed_is_ignored() -> None:
    """`/new-thread ` (empty name) → (state, [])."""
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    new_s, actions = on_msg(s, _msg("/new-thread   "))
    assert new_s is s
    assert actions == []


def test_new_thread_without_prefix_space_ignored() -> None:
    """`/new-threadfoo` must not trigger; prefix requires a space."""
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    new_s, actions = on_msg(s, _msg("/new-threadfoo"))
    assert new_s is s
    assert actions == []


# --- F08: route to bound thread ---------------------------------------


def test_regular_msg_routes_to_bound_thread() -> None:
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState(bound_threads=frozenset({"foo"}))
    new_s, actions = on_msg(s, _msg("hello world", thread_id="foo"))
    assert new_s is s
    assert len(actions) == 1
    assert isinstance(actions[0], Route)
    assert actions[0].target == "thread:foo"
    assert actions[0].msg == "hello world"


def test_unknown_thread_is_silent() -> None:
    """A message with thread_id not in bound_threads produces no routes."""
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState(bound_threads=frozenset({"foo"}))
    new_s, actions = on_msg(s, _msg("hello", thread_id="other"))
    assert new_s is s
    assert actions == []


def test_msg_without_thread_id_is_silent() -> None:
    """A msg_received with no thread_id and not /new-thread → no routes."""
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    new_s, actions = on_msg(s, _msg("hello"))
    assert new_s is s
    assert actions == []


# --- F09: non-msg events ----------------------------------------------


def test_reaction_event_ignored() -> None:
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    event = Event(
        source="esr://localhost/adapter/feishu",
        event_type="reaction_added",
        args={"msg_id": "om_1"},
    )
    new_s, actions = on_msg(s, event)
    assert new_s is s
    assert actions == []


def test_arbitrary_event_ignored() -> None:
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    event = Event(source="esr://x/adapter/y", event_type="whatever", args={})
    new_s, actions = on_msg(s, event)
    assert new_s is s
    assert actions == []
