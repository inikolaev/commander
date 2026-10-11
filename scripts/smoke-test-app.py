#!/usr/bin/env python3
"""Launch a packaged app, requiring a window and initialized shell within 30s."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="commander-smoke-shell-") as temporary:
    config = Path(temporary)
    (config / ".zshrc").write_text("HISTFILE=/dev/null\nSAVEHIST=0\nPS1='smoke> '\n")
    environment = os.environ.copy()
    environment["ZDOTDIR"] = str(config)
    result = subprocess.run(
        [str(app / "Contents/MacOS/Commander"), "--smoke-test"],
        env=environment, capture_output=True, text=True, timeout=30,
    )
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    if result.returncode != 0 or "COMMANDER_SMOKE_READY" not in result.stdout:
        raise SystemExit("Packaged app failed startup smoke test")
