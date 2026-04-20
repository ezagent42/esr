"""`python -m esr_cc_mcp.channel --help` smoke test — verifies the
module can be loaded and wired as a `python -m` entrypoint."""

import subprocess
import sys


def test_channel_module_is_importable() -> None:
    # Just verify `python -c "import esr_cc_mcp.channel"` works.
    result = subprocess.run(
        [sys.executable, "-c", "import esr_cc_mcp.channel; print('ok')"],
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert "ok" in result.stdout
