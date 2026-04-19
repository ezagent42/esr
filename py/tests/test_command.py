"""PRD 02 F09 / F10 — @command decorator + node() EDSL."""

from __future__ import annotations

import pytest

from esr.command import COMMAND_REGISTRY, _command_context, command, node, port


@pytest.fixture(autouse=True)
def _clear_registry() -> None:
    """Ensure each test starts with a clean COMMAND_REGISTRY."""
    COMMAND_REGISTRY.clear()


def test_command_registers_function() -> None:
    """Decorated function appears in COMMAND_REGISTRY under `name`."""

    @command("feishu-to-cc")
    def build() -> None:
        return None

    assert "feishu-to-cc" in COMMAND_REGISTRY
    entry = COMMAND_REGISTRY["feishu-to-cc"]
    assert entry.name == "feishu-to-cc"
    assert entry.fn is build


def test_command_returns_original_callable() -> None:
    """Decorator returns the function unchanged."""

    @command("x")
    def build() -> int:
        return 42

    assert build() == 42


def test_command_duplicate_name_raises() -> None:
    """Re-registering a command name raises ValueError."""

    @command("dup")
    def _first() -> None:
        return None

    with pytest.raises(ValueError, match=r"command dup already registered"):

        @command("dup")
        def _second() -> None:
            return None


def test_command_entry_is_frozen() -> None:
    """CommandEntry is a frozen dataclass — mutation raises."""
    from esr.command import CommandEntry

    entry = CommandEntry(name="a", fn=lambda: None)
    with pytest.raises(Exception):  # noqa: B017
        entry.name = "other"  # type: ignore[misc]


# --- PRD 02 F10: node() + `>>` edges --------------------------------------


def test_node_appended_in_context() -> None:
    """node() called inside _command_context records the node."""
    with _command_context("cmd") as ctx:
        node(id="a", actor_type="feishu_thread", handler="on_msg")
        node(id="b", actor_type="cc_session", handler="on_msg")

    assert [n.id for n in ctx.nodes] == ["a", "b"]
    assert ctx.nodes[0].actor_type == "feishu_thread"
    assert ctx.nodes[0].handler == "on_msg"


def test_node_outside_context_raises() -> None:
    """Calling node() outside a command context raises RuntimeError."""
    with pytest.raises(RuntimeError, match=r"node\(\) called outside"):
        node(id="a", actor_type="x", handler="on_msg")


def test_rshift_records_edge() -> None:
    """`a >> b` appends an edge from a.id to b.id."""
    with _command_context("cmd") as ctx:
        a = node(id="a", actor_type="t", handler="on_msg")
        b = node(id="b", actor_type="t", handler="on_msg")
        a >> b

    assert ctx.edges == [("a", "b")]


def test_rshift_chain() -> None:
    """`a >> b >> c` records two edges."""
    with _command_context("cmd") as ctx:
        a = node(id="a", actor_type="t", handler="on_msg")
        b = node(id="b", actor_type="t", handler="on_msg")
        c = node(id="c", actor_type="t", handler="on_msg")
        a >> b >> c

    assert ctx.edges == [("a", "b"), ("b", "c")]


def test_node_init_directive_stored_verbatim() -> None:
    """init_directive dict is stored on the node as given."""
    init_dir = {"action": "new_session", "args": {"label": "{{thread_id}}"}}
    with _command_context("cmd") as ctx:
        node(
            id="cc",
            actor_type="cc_session",
            handler="on_msg",
            adapter="cc_tmux",
            init_directive=init_dir,
        )

    assert ctx.nodes[0].init_directive == init_dir


def test_node_init_directive_invalid_shape_raises() -> None:
    """init_directive must be {'action': str, 'args': dict} — else TypeError."""
    with _command_context("cmd"), pytest.raises(TypeError, match=r"init_directive must be"):
        node(
            id="x",
            actor_type="t",
            handler="on_msg",
            init_directive={"no_action_key": True},  # type: ignore[arg-type]
        )


def test_node_depends_on_accepts_iterable() -> None:
    """depends_on is normalised to a tuple."""
    with _command_context("cmd") as ctx:
        node(
            id="x",
            actor_type="t",
            handler="on_msg",
            depends_on=["a", "b"],
        )

    assert ctx.nodes[0].depends_on == ("a", "b")


# --- PRD 02 F11: port.input / port.output ------------------------------


def test_port_input_records_in_context() -> None:
    """port.input records a typed input port in the current context."""
    with _command_context("cmd") as ctx:
        name = port.input("from_feishu", "FeishuMsg")

    assert name == "from_feishu"
    assert ctx.ports_in == {"from_feishu": "FeishuMsg"}


def test_port_output_records_in_context() -> None:
    """port.output records a typed output port in the current context."""
    with _command_context("cmd") as ctx:
        name = port.output("to_cc", "CCCmd")

    assert name == "to_cc"
    assert ctx.ports_out == {"to_cc": "CCCmd"}


def test_port_input_outside_context_raises() -> None:
    """port.input called outside a command context raises RuntimeError."""
    with pytest.raises(RuntimeError, match=r"port\.input\(\) called outside"):
        port.input("x", "T")


def test_port_output_outside_context_raises() -> None:
    """port.output called outside a command context raises RuntimeError."""
    with pytest.raises(RuntimeError, match=r"port\.output\(\) called outside"):
        port.output("x", "T")


def test_port_duplicate_input_name_raises() -> None:
    """Duplicate input-port name inside the same command raises ValueError."""
    with _command_context("cmd"), pytest.raises(
        ValueError, match=r"input port dup already declared"
    ):
        port.input("dup", "T")
        port.input("dup", "T")
