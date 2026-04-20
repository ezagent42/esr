"""PRD 05 F07 / F08 / F09 — feishu_app.on_msg (v0.2)."""

from __future__ import annotations

from dataclasses import replace

from esr import Event, InvokeCommand, Route


def _msg(content: str, *, thread_id: str | None = None,
         chat_id: str | None = None) -> Event:
    args: dict = {"content": content}
    if thread_id is not None:
        args["thread_id"] = thread_id
    if chat_id is not None:
        args["chat_id"] = chat_id
    return Event(source="esr://localhost/adapter/feishu", event_type="msg_received", args=args)


def _with_chat(event: Event, chat_id: str) -> Event:
    """Return a copy of the event with chat_id merged into args."""
    return replace(event, args={**event.args, "chat_id": chat_id})


# --- /new-session (v0.2) -----------------------------------------------


def test_new_session_triggers_invoke_command() -> None:
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    # args include chat_id now for the pass-through
    event = _with_chat(_msg("/new-session esr-dev tag=dev-root"), "oc_abc")

    new_s, actions = on_msg(s, event)
    assert new_s.bound_threads == frozenset({"dev-root"})
    assert new_s.active_thread_by_chat == {"oc_abc": "dev-root"}
    assert len(actions) == 1
    ic = actions[0]
    assert ic.name == "feishu-thread-session"
    assert ic.params == {
        "thread_id": "dev-root",
        "chat_id": "oc_abc",
        "workspace": "esr-dev",
        "tag": "dev-root",
    }


def test_new_thread_legacy_alias_still_works() -> None:
    """v0.1 compat alias — /new-thread <tag> → InvokeCommand with workspace=legacy."""
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    event = _with_chat(_msg("/new-thread alpha"), "oc_x")
    new_s, actions = on_msg(s, event)
    assert new_s.bound_threads == frozenset({"alpha"})
    assert len(actions) == 1
    ic = actions[0]
    assert ic.name == "feishu-thread-session"
    assert ic.params["thread_id"] == "alpha"
    assert ic.params["workspace"] == "legacy"


def test_at_prefix_addressing_routes_to_named_thread() -> None:
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState(bound_threads=frozenset({"alpha", "beta"}),
                       active_thread_by_chat={"oc_x": "alpha"})
    event = _with_chat(_msg("@beta hello there"), "oc_x")
    new_s, actions = on_msg(s, event)
    assert len(actions) == 1
    r = actions[0]
    assert isinstance(r, Route)
    assert r.target == "thread:beta"
    assert r.msg["args"]["content"] == "hello there"


def test_non_command_msg_routes_to_active_thread_by_chat() -> None:
    from esr_handler_feishu_app.on_msg import on_msg
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState(bound_threads=frozenset({"alpha"}),
                       active_thread_by_chat={"oc_x": "alpha"})
    event = _with_chat(_msg("hello plain"), "oc_x")
    new_s, actions = on_msg(s, event)
    assert len(actions) == 1
    r = actions[0]
    assert r.target == "thread:alpha"


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


def test_state_tracks_active_thread_per_chat() -> None:
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    s2 = s.with_active_thread("oc_a", "dev-1")
    assert s2.active_thread_by_chat == {"oc_a": "dev-1"}
    # immutability
    assert s.active_thread_by_chat == {}


def test_state_tracks_last_chat_id() -> None:
    from esr_handler_feishu_app.state import FeishuAppState

    s = FeishuAppState()
    s2 = s.with_last_chat_id("oc_abc")
    assert s2.last_chat_id == "oc_abc"
