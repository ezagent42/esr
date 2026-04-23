"""Smoke test: _ipc_common/ package imports cleanly."""


def test_ipc_common_importable() -> None:
    import _ipc_common  # noqa: F401
