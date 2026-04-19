"""Fixture — simulates an adversarial empty-body stub."""
async def run() -> None:
    pass


def stub_dict_return() -> dict[str, object]:
    return {"ok": False, "error": "not yet wired"}
